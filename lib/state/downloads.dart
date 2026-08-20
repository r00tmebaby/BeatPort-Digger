library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../engine/atomic_write.dart';
import '../engine/catalog.dart';
import '../engine/download.dart';
import '../engine/download_history.dart';
import '../engine/errors.dart';
import '../engine/ffmpeg.dart';
import '../engine/media_store.dart';
import '../engine/models.dart';
import '../engine/throughput.dart';
import '../engine/transfer.dart' show TransferPool;

enum JobStatus { queued, running, completed, failed, cancelled }

/// How many restored records to adopt between yields to the event loop.
/// Each one is only map work, but a queue in the hundreds of thousands makes
/// even that seconds in total, and it happens while the app is drawing its
/// first frames. Sized to keep one slice comfortably inside a frame.
const int _restoreChunk = 2000;

/// Reads and decodes the history file. Runs inside [Isolate.run]: the file
/// grows past fifty megabytes once the history holds six figures, and a
/// single jsonDecode of it on the UI isolate was most of the startup freeze.
List<HistoryEntry> _readHistoryFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  try {
    final payload = jsonDecode(file.readAsStringSync());
    if (payload is! List) return const [];
    final entries = <HistoryEntry>[];
    for (final raw in payload.whereType<Map<String, dynamic>>()) {
      final entry = HistoryEntry.fromJson(raw);
      if (entry != null) entries.add(entry);
    }
    return entries;
  } on Object {
    return const [];
  }
}

/// Encodes and writes the history from a snapshot of its entries. Runs inside
/// [Isolate.run], where building a payload of tens of megabytes costs the UI
/// nothing. The write stays atomic: this file was once caught truncated to
/// zero bytes mid-write, and it is the skip-list for every download ever
/// made, which is not a file to lose.
Future<void> _writeHistoryFile(String path, List<HistoryEntry> entries) {
  final buffer = StringBuffer('[');
  for (var i = 0; i < entries.length; i++) {
    if (i > 0) buffer.write(',');
    buffer.write(jsonEncode(entries[i].toJson()));
  }
  buffer.write(']');
  return writeFileAtomically(File(path), buffer.toString());
}

/// Stats every recorded file and reports the entries whose presence flipped.
/// Runs inside [Isolate.run]: a six-figure history is as many stat calls.
List<(int, bool)> _statHistoryPaths(List<(int, String, bool)> records) => [
  for (final (id, path, present) in records)
    if (File(path).existsSync() != present) (id, !present),
];

/// Parses the queue file, tolerating damaged lines. Runs inside
/// [Isolate.run]: the file holds one JSON line per outstanding job and has
/// reached hundreds of megabytes in real use, which is far too much decoding
/// to do where the UI lives.
Future<List<DownloadJob>> _readQueueFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return const [];

  final jobs = <DownloadJob>[];
  try {
    final lines = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final payload = jsonDecode(line);
        if (payload is! Map<String, dynamic>) continue;
        final job = DownloadJob.fromJson(payload);
        if (job != null) jobs.add(job);
      } on FormatException {
        continue;
      }
    }
  } on Object {
    // Best-effort: keep whatever parsed before the failure.
  }
  return jobs;
}

/// Total tries for one job, including the first. Only transient failures are
/// retried; a refusal the account cannot satisfy fails straight away.
const int maxJobAttempts = 3;

/// Ceiling on tracks downloading at once.
///
/// What this actually costs depends on the quality. A direct download (FLAC,
/// and the AAC qualities the account can take outright) is one connection per
/// track, so this number is the connection count. A track that falls back to
/// the stream fetches [segmentWindow] segments at once and ends with an
/// ffmpeg remux, so those multiply.
///
/// Metadata calls are gated separately by the client's own limiter, so raising
/// this does not increase the rate of requests to the API itself.
const int maxParallelDownloads = 64;

class DownloadJob {
  DownloadJob(this.track, {this.status = JobStatus.queued});

  final Track track;
  Cancellation cancellation = Cancellation();

  JobStatus status;
  DownloadProgress? progress;
  String? path;
  String? error;

  bool remuxed = true;

  bool isSample = false;

  /// Why a sample was written instead of the full track, e.g. because the
  /// account has no active subscription. Null unless [isSample] is true.
  String? sampleReason;

  /// How many times this job has been handed to the downloader.
  int attempts = 0;

  /// Lower-cased sort keys for the Downloads list, computed once each.
  /// Lower-casing inside a comparator allocates two strings per comparison,
  /// which is what dominates the sort once the queue holds six figures.
  late final String titleKey = track.title.toLowerCase();
  late final String artistKey = track.artistNames.toLowerCase();

  bool get isFinished =>
      status == JobStatus.completed ||
      status == JobStatus.failed ||
      status == JobStatus.cancelled;

  /// Returns the job to a fresh queued state for a retry, keeping its place in
  /// the list so the row does not jump around under the user.
  void reset() {
    status = JobStatus.queued;
    cancellation = Cancellation();
    progress = null;
    path = null;
    error = null;
    remuxed = true;
    isSample = false;
    sampleReason = null;
    attempts = 0;
  }

  Map<String, dynamic> toJson() => {
    'track': track.toJson(),
    if (status == JobStatus.failed) 'failed': true,
    if (error != null) 'error': error,
  };

  static DownloadJob? fromJson(Map<String, dynamic> json) {
    final raw = json['track'];
    if (raw is! Map<String, dynamic>) return null;
    final track = Track.fromJson(raw);
    if (track.id == null) return null;

    final failed = json['failed'] == true;
    final job = DownloadJob(
      track,
      status: failed ? JobStatus.failed : JobStatus.queued,
    );
    final error = json['error'];
    if (failed && error is String) job.error = error;
    return job;
  }
}

class DownloadQueue extends ChangeNotifier {
  DownloadQueue({int maxConcurrent = 4}) : _maxConcurrent = maxConcurrent;

  int _maxConcurrent;

  int get maxConcurrent => _maxConcurrent;

  set maxConcurrent(int value) {
    final clamped = value.clamp(1, maxParallelDownloads);
    if (clamped == _maxConcurrent) return;
    _maxConcurrent = clamped;
    _notify();
    unawaited(saveSettings());

    unawaited(_pump());
  }

  final Ffmpeg ffmpeg = Ffmpeg();

  AudioQuality quality = AudioQuality.lossless;

  set preferredQuality(AudioQuality value) {
    if (quality == value) return;
    quality = value;
    _notify();
    unawaited(saveSettings());
  }

  Downloader? _downloader;
  Directory? _destination;
  int _running = 0;
  bool _disposed = false;

  /// Set once the window is closing: no new downloads start, and the save
  /// schedulers stand down so nothing rewrites the state files after the
  /// final flush in [prepareForExit].
  bool _shuttingDown = false;

  Timer? _notifyTimer;
  bool _notifyPending = false;

  bool get _busy => _running > 0 || discovering;

  /// Publishes a change to listeners.
  ///
  /// While the queue is working it changes many times a second, and because
  /// the app keeps every page built inside an IndexedStack, each of those
  /// changes rebuilds Downloads, Search, Harmonic, Link and Settings together.
  /// Batching them leaves the frame budget free for scrolling and playback.
  /// When nothing is running the change goes out immediately, so a one-off
  /// action still feels instant.
  void _notify() {
    if (_disposed) return;
    if (!_busy) {
      _flushNotify();
      return;
    }
    if (_notifyPending) return;
    _notifyPending = true;
    _notifyTimer = Timer(_notifyInterval, _flushNotify);
  }

  /// How long to batch changes for.
  ///
  /// Every listener in the app redraws on each of these, so the more work is
  /// in flight the less often it is worth doing. At sixty-four downloads the
  /// individual progress bars crawl anyway, so a slower refresh is not
  /// visible, while the frames it frees up very much are.
  Duration get _notifyInterval {
    final scaled = 120 + _running * 4;
    return Duration(milliseconds: scaled > 400 ? 400 : scaled);
  }

  void _flushNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _notifyPending = false;
    if (_disposed) return;
    notifyListeners();
  }

  // Segment-level progress fires far more often than the UI needs to redraw
  // (every batch of every concurrent job); at maxConcurrent=16 that is
  // hundreds of calls a second. [_shouldPublishProgress] drops the
  // uninteresting ones before they ever reach [_notify], which then batches
  // whatever is left.
  static const int _progressByteStep = 256 * 1024;

  void _notifyProgress() => _notify();

  bool _shouldPublishProgress(
    DownloadProgress? previous,
    DownloadProgress next,
  ) {
    if (previous == null) return true;
    if (next.total != previous.total || next.segmented != previous.segmented) {
      return true;
    }
    if (next.segmented && next.completed != previous.completed) return true;
    if (next.total > 0 && next.completed >= next.total) return true;
    if (next.bytes - previous.bytes >= _progressByteStep) return true;
    return false;
  }

  final List<DownloadJob> _jobs = [];

  final Map<int, DownloadJob> _byId = {};

  /// Jobs waiting for a slot, in the order they will run.
  ///
  /// Scanning [_jobs] for the next queued entry was linear per completion,
  /// which turns a large queue quadratic: with 100,000 mostly-finished jobs
  /// the scan walked the whole list every time a download ended. Entries here
  /// are removed lazily, so a job cancelled while waiting is simply skipped
  /// when its turn comes.
  final Queue<DownloadJob> _pending = Queue();

  /// Jobs downloading right now, in the order they started.
  ///
  /// Never longer than [maxConcurrent], so the UI can show what is in flight
  /// without scanning a queue that may hold six figures.
  final List<DownloadJob> _active = [];

  int _unfinished = 0;
  int _revision = 0;
  int _structure = 0;

  List<DownloadJob> get jobs => UnmodifiableListView(_jobs);

  List<DownloadJob> get active => UnmodifiableListView(_active);

  /// Bumped whenever a job is added, removed, or changes status. The Downloads
  /// list caches its derived views against this rather than rebuilding them
  /// from every job on every notification.
  int get revision => _revision;

  /// Bumped only when jobs are added or removed. Orderings that do not depend
  /// on status can cache against this and survive an entire bulk download
  /// without re-sorting.
  int get structureRevision => _structure;

  /// Applies a status change and keeps the unfinished count in step. Every
  /// transition goes through here so [activeCount] never has to count.
  void _setStatus(DownloadJob job, JobStatus status) {
    if (job.status == status) return;
    final wasRunning = job.status == JobStatus.running;
    if (!job.isFinished) _unfinished -= 1;
    job.status = status;
    if (!job.isFinished) _unfinished += 1;

    if (status == JobStatus.running) {
      _active.add(job);
    } else if (wasRunning) {
      _active.remove(job);
    }
    _revision += 1;

    // Only failures and cancellations are worth a rewrite of the queue file.
    // Starting a job persists nothing because a running job restores as
    // queued anyway; a completion persists nothing because restore consults
    // the history and skips anything already on disk. Rewriting a six-figure
    // queue for each of those kept hundreds of megabytes churning through
    // the disk for the whole run. Completions still mark the file stale so
    // the next structural save, or the one on exit, trims them out.
    if (status == JobStatus.failed || status == JobStatus.cancelled) {
      _scheduleQueueSave();
    } else if (status == JobStatus.completed) {
      _queueStale = true;
    }
  }

  final Map<int, HistoryEntry> _history = {};
  Timer? _historyFlush;

  List<HistoryEntry> get history =>
      _history.values.toList()
        ..sort((a, b) => b.completedAt.compareTo(a.completedAt));

  int _missingCount = 0;

  int get historyCount => _history.length;

  /// Counted as entries change rather than scanned. The settings page reads
  /// this on every build, and a scan of a six-figure history there was enough
  /// to stall the whole app while downloads ran.
  int get missingCount => _missingCount;

  void _putHistory(HistoryEntry entry) {
    final previous = _history[entry.trackId];
    if (previous != null && !previous.present) _missingCount -= 1;
    if (!entry.present) _missingCount += 1;
    _history[entry.trackId] = entry;
  }

  HistoryMark historyMark(Track track) {
    final id = track.id;
    if (id == null) return HistoryMark.none;
    final entry = _history[id];
    if (entry == null) return HistoryMark.none;
    return entry.present ? HistoryMark.saved : HistoryMark.missing;
  }

  HistoryEntry? historyEntry(int trackId) => _history[trackId];

  void _recordHistory(Track track, String path, String qualityLabel) {
    final id = track.id;
    if (id == null) return;
    _putHistory(
      HistoryEntry(
        trackId: id,
        title: track.title,
        artists: track.artistNames,
        path: path,
        quality: qualityLabel,
        completedAt: _now(),
        present: true,
      ),
    );
    _scheduleHistorySave();
  }

  DateTime _now() => DateTime.now();

  bool get isBusy => _unfinished > 0;
  int get activeCount => _unfinished;

  final ThroughputMeter _throughput = ThroughputMeter();

  /// Combined download rate across every running job, over the last few
  /// seconds. This is the figure that says whether sixty-four parallel
  /// downloads are actually faster than eight, which nothing in the app
  /// answered before.
  double get bytesPerSecond => _throughput.bytesPerSecond(DateTime.now());

  /// Bytes downloaded since the app started.
  int get bytesThisSession => _throughput.total;

  bool _ffmpegReady = false;
  bool _ffmpegChecked = false;
  bool installing = false;
  InstallProgress? installProgress;
  String? installError;

  bool get ffmpegReady => _ffmpegReady;
  bool get ffmpegChecked => _ffmpegChecked;
  bool get canInstallFfmpeg => ffmpeg.canInstall;

  void bind(Catalog catalog) {
    if (_downloader?.catalog == catalog) return;
    _downloader?.close();

    // Transfers run on the pool's worker isolates: the UI isolate resolves
    // the catalog metadata and receives throttled progress, while the bytes,
    // the decryption and the remuxes live on their own threads. Before this
    // every segment body crossed the UI event loop, which is what made the
    // window sluggish and throughput sag while the queue ran.
    _downloader = Downloader(
      catalog: catalog,
      ffmpeg: ffmpeg,
      transferPool: TransferPool(totalSegmentSlots: totalSegmentWindow),
    );

    // A queue restored from disk has nothing to run against until a catalog
    // arrives, so this is where that work actually starts.
    unawaited(_pump());
  }

  Future<void> checkFfmpeg() async {
    if (_ffmpegChecked) return;
    _ffmpegReady = await ffmpeg.resolve() != null;
    _ffmpegChecked = true;
    _notify();
  }

  Future<bool> installFfmpeg() async {
    if (installing) return false;
    installing = true;
    installError = null;
    installProgress = null;
    _notify();

    try {
      await ffmpeg.install(
        onProgress: (progress) {
          installProgress = progress;
          _notify();
        },
      );
      _ffmpegReady = true;
      _ffmpegChecked = true;
      return true;
    } on Object catch (exception) {
      installError = exception.toString();
      return false;
    } finally {
      installing = false;
      _notify();
    }
  }

  String? destinationOverride;

  /// Whether a bulk enqueue passes over tracks already saved on disk.
  ///
  /// Applies to sweeps only, never to a deliberate single download, and only
  /// while the file is still where history says it is: delete it and the track
  /// becomes eligible again.
  bool skipDownloaded = true;

  set skipExisting(bool value) {
    if (skipDownloaded == value) return;
    skipDownloaded = value;
    _notify();
    unawaited(saveSettings());
  }

  int _skippedDownloaded = 0;

  /// Running total of tracks a sweep passed over as already downloaded.
  int get skippedDownloaded => _skippedDownloaded;

  bool colourByStatus = true;

  set statusColours(bool value) {
    if (colourByStatus == value) return;
    colourByStatus = value;
    _notify();
    unawaited(saveSettings());
  }

  String folderTemplate = '';

  String fileTemplate = defaultFileTemplate;

  set folders(String value) {
    if (folderTemplate == value) return;
    folderTemplate = value;
    _notify();
    unawaited(saveSettings());
  }

  set files(String value) {
    final cleaned = value.trim();
    if (cleaned.isEmpty || fileTemplate == cleaned) return;
    fileTemplate = cleaned;
    _notify();
    unawaited(saveSettings());
  }

  Future<String> destinationPath() async => (await destination()).path;

  Future<Directory> destination() async {
    final override = destinationOverride;
    if (override != null && override.isNotEmpty) return Directory(override);
    if (_destination != null) return _destination!;
    final base = Platform.isAndroid || Platform.isIOS
        ? await getApplicationDocumentsDirectory()
        : await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
    return _destination = Directory(
      '${base.path}${Platform.pathSeparator}Beatport',
    );
  }

  Future<void> setDestination(String? path) async {
    destinationOverride = path;
    _notify();
    await saveSettings();
  }

  Future<File> _settingsFile() async {
    final support = await getApplicationSupportDirectory();
    return File(
      '${support.path}${Platform.pathSeparator}download_settings.json',
    );
  }

  /// Loads everything the queue keeps on disk, in the order the later steps
  /// depend on: history first, because restoring the queue consults it to
  /// skip tracks that already downloaded.
  Future<void> restore() async {
    await loadSettings();
    await loadHistory();
    await loadQueue();
  }

  Future<void> loadSettings() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return;
      final payload = jsonDecode(await file.readAsString());
      if (payload is! Map<String, dynamic>) return;

      final savedQuality = payload['quality'];
      if (savedQuality is String) {
        for (final option in AudioQuality.values) {
          if (option.value == savedQuality) quality = option;
        }
      }
      final concurrent = payload['max_concurrent'];
      if (concurrent is int) {
        _maxConcurrent = concurrent.clamp(1, maxParallelDownloads);
      }
      final folder = payload['destination'];
      if (folder is String && folder.isNotEmpty) destinationOverride = folder;
      final folders = payload['folder_template'];
      if (folders is String) folderTemplate = folders;
      final files = payload['file_template'];
      if (files is String && files.trim().isNotEmpty) fileTemplate = files;
      final colours = payload['status_colours'];
      if (colours is bool) colourByStatus = colours;
      final skip = payload['skip_downloaded'];
      if (skip is bool) skipDownloaded = skip;

      _notify();
    } on Object {
      // Best-effort settings load; fall back to defaults on any error.
    }
  }

  Future<void> saveSettings() async {
    try {
      // Atomic so a kill mid-write cannot truncate the file: settings lost
      // that way would silently come back as defaults, moving the download
      // folder without anyone having changed it.
      await writeFileAtomically(
        await _settingsFile(),
        jsonEncode({
          'quality': quality.value,
          'max_concurrent': _maxConcurrent,
          'folder_template': folderTemplate,
          'file_template': fileTemplate,
          'status_colours': colourByStatus,
          'skip_downloaded': skipDownloaded,
          if (destinationOverride != null) 'destination': destinationOverride,
        }),
      );
    } on Object {
      // Best-effort settings save; ignore write failures (e.g. read-only fs).
    }
  }

  Future<File> _historyFile() async {
    final support = await getApplicationSupportDirectory();
    return File(
      '${support.path}${Platform.pathSeparator}download_history.json',
    );
  }

  Future<void> loadHistory() async {
    try {
      final path = (await _historyFile()).path;
      final entries = await Isolate.run(() => _readHistoryFile(path));

      var adopted = 0;
      for (final entry in entries) {
        // A download that completed while the file was still being read is
        // newer than anything the file says about the same track.
        if (!_history.containsKey(entry.trackId)) _putHistory(entry);
        if (++adopted % _restoreChunk == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      _notify();
    } on Object {
      // Best-effort history load; a corrupt/missing file just starts empty.
    }
    unawaited(verifyHistory());
  }

  Future<void> verifyHistory() async {
    if (_history.isEmpty) return;
    final records = [
      for (final entry in _history.values)
        (entry.trackId, entry.path, entry.present),
    ];
    final flips = await Isolate.run(() => _statHistoryPaths(records));
    if (flips.isEmpty) return;

    for (final (id, present) in flips) {
      final entry = _history[id];
      if (entry != null && entry.present != present) {
        _putHistory(entry.copyWith(present: present));
      }
    }
    _notify();
    _scheduleHistorySave();
  }

  Future<void> removeMissingHistory() async {
    _history.removeWhere((_, entry) => !entry.present);
    _missingCount = 0;
    _notify();
    await _saveHistory();
  }

  Future<void> clearHistory() async {
    _history.clear();
    _missingCount = 0;
    _notify();
    await _saveHistory();
  }

  bool _historyDirty = false;
  bool _historySaving = false;

  /// How long to sit on history changes before writing them out.
  ///
  /// The write costs a full pass over every entry, so the bigger the history
  /// the less often it is worth making. What a longer gap risks is only the
  /// most recent completions: a crash forgets they are on disk and downloads
  /// them again.
  Duration get _historySaveDelay {
    final seconds = _history.length ~/ 20000;
    if (seconds < 1) return const Duration(milliseconds: 500);
    return Duration(seconds: seconds > 30 ? 30 : seconds);
  }

  /// Marks the history as needing a save without resetting a pending timer.
  ///
  /// The old debounce re-armed itself on every completion, so a steady rate
  /// of finished downloads pushed the save back indefinitely: with sixty-four
  /// tracks completing continuously the file could go unwritten for the
  /// whole run.
  void _scheduleHistorySave() {
    _historyDirty = true;
    if (!_shuttingDown && !(_historyFlush?.isActive ?? false)) {
      _historyFlush = Timer(_historySaveDelay, () => unawaited(_saveHistory()));
    }
    _notify();
  }

  /// Writes the history, coalescing overlapping calls. Changes made while a
  /// save runs trigger another pass rather than being lost.
  Future<void> _saveHistory() async {
    _historyFlush?.cancel();
    _historyDirty = true;
    if (_historySaving) return;
    _historySaving = true;
    try {
      while (_historyDirty) {
        _historyDirty = false;
        await _writeHistory();
      }
    } finally {
      _historySaving = false;
    }
  }

  Future<void> _writeHistory() async {
    try {
      // Encoded and written in a worker isolate. This used to be sliced
      // jsonEncode calls on the UI isolate, but the final assembly of a
      // fifty-megabyte payload cannot be sliced, and at today's download
      // rate the file is dirty again before each save finishes, so the UI
      // was paying that assembly almost continuously.
      final path = (await _historyFile()).path;
      final entries = _history.values.toList();
      await Isolate.run(() => _writeHistoryFile(path, entries));
    } on Object {
      // Best-effort history save; ignore write failures (e.g. read-only fs).
    }
  }

  /// How many records to encode before yielding to the event loop while
  /// saving. Encoding a six-figure queue in one go would drop frames, so the
  /// work is broken into slices well under a frame's budget.
  static const int _queueSaveChunk = 500;

  static const Duration _queueSaveDelay = Duration(seconds: 5);

  /// How long to wait before writing the queue out.
  ///
  /// Rewriting the file costs a pass over every outstanding job, so a large
  /// queue is saved less often. There is little to lose by it: the entries are
  /// almost all still just "queued", and the worst a crash costs is a few
  /// tracks downloaded twice.
  Duration get _saveDelay {
    final seconds = _jobs.length ~/ 2000;
    return seconds <= _queueSaveDelay.inSeconds
        ? _queueSaveDelay
        : Duration(seconds: seconds > 60 ? 60 : seconds);
  }

  Timer? _queueFlush;
  bool _queueDirty = false;
  bool _queueSaving = false;

  /// Set when the file merely lists jobs that have since completed. Unlike
  /// [_queueDirty] this never drives a save of its own: restore skips those
  /// jobs through the history anyway, so trimming them can wait for the next
  /// save something else asks for, or the one on exit. Were completions to
  /// set [_queueDirty] instead, a single failure mid-run would start a save
  /// loop that rewrites the file continuously for as long as tracks finish.
  bool _queueStale = false;

  Future<File> _queueFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}${Platform.pathSeparator}download_queue.jsonl');
  }

  /// Marks the queue as needing a save without resetting an already pending
  /// one, so a continuous stream of changes still reaches disk on schedule
  /// instead of pushing the write back indefinitely.
  void _scheduleQueueSave() {
    if (_shuttingDown) return;
    _queueDirty = true;
    if (_queueFlush?.isActive ?? false) return;
    _queueFlush = Timer(_saveDelay, () => unawaited(saveQueue()));
  }

  /// Restores work that was outstanding when the app last closed.
  ///
  /// Running jobs come back queued, failed ones come back failed so the retry
  /// button still works, and anything already downloaded is skipped. Call
  /// after [loadHistory] so that last check has something to consult.
  Future<void> loadQueue() async {
    final restored = <DownloadJob>[];
    try {
      // Parsed in a worker isolate: reading this file used to freeze the app
      // for as long as the parse took, and the parse is proportional to how
      // much was queued when the app last closed. Adoption stays here, in
      // slices, because it touches live state.
      final path = (await _queueFile()).path;
      final jobs = await Isolate.run(() => _readQueueFile(path));

      var adopted = 0;
      for (final job in jobs) {
        if (++adopted % _restoreChunk == 0) {
          await Future<void>.delayed(Duration.zero);
        }

        final id = job.track.id!;
        if (_byId.containsKey(id)) continue;
        if (_history[id]?.present ?? false) continue;

        _byId[id] = job;
        restored.add(job);
        if (!job.isFinished) {
          _unfinished += 1;
          _pending.add(job);
        }
      }
    } on Object {
      // Best-effort restore; whatever was adopted before the failure is kept.
    }

    if (restored.isEmpty) return;
    _jobs.addAll(restored);
    _structure += 1;
    _revision += 1;
    _notify();
    unawaited(_pump());
  }

  /// Writes the outstanding queue, coalescing overlapping calls. Structural
  /// changes made while a save is running trigger another pass rather than
  /// being lost; completions landing mid-write only mark the file stale and
  /// wait for the next save.
  Future<void> saveQueue() async {
    _queueFlush?.cancel();
    if (_queueSaving) return;
    _queueSaving = true;
    try {
      do {
        _queueDirty = false;
        _queueStale = false;
        await _writeQueue();
      } while (_queueDirty);
    } finally {
      _queueSaving = false;
    }
  }

  Future<void> _writeQueue() async {
    try {
      final file = await _queueFile();
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');

      // Jobs finish while this runs, so iterate a snapshot; each record's
      // status is read at encode time, which means a job that completed
      // mid-write is simply left out.
      final snapshot = List.of(_jobs);
      final sink = temp.openWrite();
      var written = 0;
      // Lines are batched into one buffer per slice and handed to the sink
      // as a single write. Writing line by line pushed a hundred thousand
      // separate events through the sink, which took ten times as long as
      // the encoding and held the isolate up between yields.
      final buffer = StringBuffer();
      try {
        for (final job in snapshot) {
          if (job.status == JobStatus.completed ||
              job.status == JobStatus.cancelled) {
            continue;
          }
          buffer.writeln(jsonEncode(job.toJson()));
          if (++written % _queueSaveChunk == 0) {
            sink.write(buffer.toString());
            buffer.clear();
            await Future<void>.delayed(Duration.zero);
          }
        }
        if (buffer.isNotEmpty) sink.write(buffer.toString());
        await sink.flush();
      } finally {
        await sink.close();
      }

      // One atomic swap, so a crash mid-write cannot leave a half queue in
      // place of the real one.
      await temp.rename(file.path);
    } on Object {
      // Best-effort queue save; ignore write failures (e.g. read-only fs).
    }
  }

  DownloadJob? jobFor(Track track) {
    final id = track.id;
    return id == null ? null : _byId[id];
  }

  int _firstQueuedIndex() {
    for (var i = 0; i < _jobs.length; i++) {
      if (_jobs[i].status == JobStatus.queued) return i;
    }
    return _jobs.length;
  }

  bool _isRetryable(DownloadJob job) =>
      job.status == JobStatus.failed || job.status == JobStatus.cancelled;

  /// Marks [track] as wanted, without deciding where it runs.
  ///
  /// [queued] is the job now waiting to download, if any. [placement] is set
  /// only when that job is new and still needs a position in [_jobs]; a track
  /// already present but finished unsuccessfully is reused where it stands,
  /// because removing and re-appending it would be a linear scan per track and
  /// makes retrying a large queue quadratic.
  ///
  /// [bulk] marks the track as part of a sweep rather than a deliberate pick,
  /// which is what [skipDownloaded] applies to.
  ({DownloadJob? placement, DownloadJob? queued}) _prepare(
    Track track, {
    required bool bulk,
  }) {
    final id = track.id;
    if (id == null) return (placement: null, queued: null);

    // Already on disk from an earlier sweep. Repeat digs lean on this, which
    // is why it counts skips rather than silently doing nothing.
    if (bulk && skipDownloaded && (_history[id]?.present ?? false)) {
      _skippedDownloaded += 1;
      return (placement: null, queued: null);
    }

    final existing = _byId[id];
    if (existing != null) {
      if (!_isRetryable(existing)) return (placement: null, queued: null);
      existing.reset();
      _unfinished += 1;
      _revision += 1;
      return (placement: null, queued: existing);
    }

    final job = DownloadJob(track);
    _byId[id] = job;
    _unfinished += 1;
    _revision += 1;
    _structure += 1;
    return (placement: job, queued: job);
  }

  /// True when [track] became queued, whether as a new job or a reused one.
  bool _add(Track track, {bool bulk = false}) {
    final result = _prepare(track, bulk: bulk);
    final job = result.queued;
    if (job == null) return false;

    final placement = result.placement;
    if (placement != null) _jobs.add(placement);
    _pending.add(job);
    return true;
  }

  void enqueue(Track track) {
    if (!_add(track)) return;
    _scheduleQueueSave();
    _notify();
    unawaited(_pump());
  }

  void enqueueFirst(Track track) {
    if (_addFirst([track]) == 0) return;
    _scheduleQueueSave();
    _notify();
    unawaited(_pump());
  }

  /// Places a batch ahead of the work still waiting, keeping the batch's own
  /// order. The insertion point is found once and the batch goes in as a
  /// single splice rather than one shifting insert per track.
  int _addFirst(Iterable<Track> tracks, {bool bulk = false}) {
    final batch = <DownloadJob>[];
    final reused = <DownloadJob>{};

    for (final track in tracks) {
      final result = _prepare(track, bulk: bulk);
      final job = result.queued;
      if (job == null) continue;
      batch.add(job);
      if (result.placement == null) reused.add(job);
    }
    if (batch.isEmpty) return 0;

    // Jobs being retried already sit somewhere in the list. Lifting them out
    // in one pass keeps this linear in the queue rather than in the batch
    // size times the queue.
    if (reused.isNotEmpty) {
      _jobs.removeWhere(reused.contains);
      _structure += 1;
    }

    _jobs.insertAll(_firstQueuedIndex(), batch);
    for (final job in batch.reversed) {
      _pending.addFirst(job);
    }
    return batch.length;
  }

  int enqueueAll(Iterable<Track> tracks) {
    var added = 0;
    for (final track in tracks) {
      if (_add(track, bulk: true)) added += 1;
    }
    if (added > 0) {
      _scheduleQueueSave();
      _notify();
      unawaited(_pump());
    }
    return added;
  }

  int enqueueAllFirst(Iterable<Track> tracks) {
    final added = _addFirst(tracks, bulk: true);
    if (added > 0) {
      _scheduleQueueSave();
      _notify();
      unawaited(_pump());
    }
    return added;
  }

  bool discovering = false;
  int discovered = 0;

  /// How many tracks this walk passed over as already downloaded.
  int discoverSkipped = 0;
  String? discoverLabel;
  String? discoverError;
  Cancellation? _discovery;

  bool get isDiscovering => discovering;

  void cancelDiscovery() {
    _discovery?.cancel();
    _notify();
  }

  /// Retitles the walk in progress. A dig moving between genres uses this so
  /// the discovery banner names the category being worked on.
  void describeDiscovery(String label) {
    if (!discovering || discoverLabel == label) return;
    discoverLabel = label;
    _notify();
  }

  Future<int> enqueueStream(
    Stream<Track> source, {
    required String label,
  }) async {
    if (discovering) return 0;
    final cancellation = Cancellation();
    final skippedBefore = _skippedDownloaded;
    _discovery = cancellation;
    discovering = true;
    discovered = 0;
    discoverSkipped = 0;
    discoverLabel = label;
    discoverError = null;
    _notify();

    try {
      var sinceNotify = 0;
      await for (final track in source) {
        if (cancellation.isCancelled) break;
        if (_add(track, bulk: true)) discovered += 1;

        // Counts move per track so the digger's progress line actually
        // climbs; _notify batches them into a few updates a second, so this
        // costs nothing. A sweep over material already on disk queues nothing
        // and used to sit there looking stalled.
        discoverSkipped = _skippedDownloaded - skippedBefore;
        _notify();

        // Starting downloads and writing the queue file are the expensive
        // parts, so those stay on a checkpoint.
        if (++sinceNotify >= 25) {
          sinceNotify = 0;
          _scheduleQueueSave();
          unawaited(_pump());
        }
      }
      unawaited(_pump());
    } on Object catch (exception) {
      // Whatever the walk found before it broke stays queued, so a failure
      // partway through a long discovery costs progress but not work.
      discoverError = exception.toString();
    } finally {
      discoverSkipped = _skippedDownloaded - skippedBefore;
      discovering = false;
      _discovery = null;
      if (discovered > 0) _scheduleQueueSave();
      _notify();
    }
    return discovered;
  }

  void cancel(DownloadJob job) {
    if (job.isFinished) return;
    job.cancellation.cancel();
    if (job.status == JobStatus.queued) {
      // The stale entry left in _pending is skipped when its turn comes.
      _setStatus(job, JobStatus.cancelled);
    }
    _notify();
    unawaited(_pump());
  }

  void _forget(DownloadJob job) {
    final id = job.track.id;
    if (id != null && identical(_byId[id], job)) _byId.remove(id);
  }

  void clearFinished() {
    final before = _jobs.length;
    _jobs.removeWhere((job) {
      if (!job.isFinished) return false;
      _forget(job);
      return true;
    });
    if (_jobs.length == before) return;
    _structure += 1;
    _revision += 1;
    _notify();
    _scheduleQueueSave();
  }

  void cancelAll() {
    _discovery?.cancel();
    for (final job in _jobs) {
      if (job.isFinished) continue;
      job.cancellation.cancel();
      if (job.status == JobStatus.queued) {
        _setStatus(job, JobStatus.cancelled);
      }
    }
    _notify();
  }

  void clearAll() {
    cancelAll();
    clearFinished();
  }

  Future<void> _pump() async {
    if (_shuttingDown) return;
    final downloader = _downloader;
    if (downloader == null) return;

    while (_running < maxConcurrent) {
      final next = _nextPending();
      if (next == null) return;

      _running += 1;
      next.attempts += 1;
      _setStatus(next, JobStatus.running);
      _notify();
      unawaited(_run(downloader, next));
    }
  }

  DownloadJob? _nextPending() {
    while (_pending.isNotEmpty) {
      final job = _pending.removeFirst();
      if (job.status == JobStatus.queued) return job;
    }
    return null;
  }

  /// Puts a job back after a transient failure.
  ///
  /// It waits first, because a CDN error or a dropped socket recurs
  /// immediately and would otherwise burn the whole retry budget in
  /// milliseconds. It then goes to the head rather than the tail, so a track
  /// that stumbled once is not deferred behind another hundred thousand.
  void _scheduleRetry(DownloadJob job) {
    Timer(Duration(seconds: 2 * job.attempts), () {
      if (_disposed || job.status != JobStatus.queued) return;
      _pending.addFirst(job);
      unawaited(_pump());
    });
  }

  /// Whether a failure is worth another go. A refusal the account cannot
  /// satisfy, or a dead session, will fail the same way every time; a rate
  /// limit, a gateway error or a dropped socket will not.
  bool _isTransient(Object exception) {
    if (exception is AuthException) return false;
    if (exception is BeatportException) {
      return retryableStatuses.contains(exception.status);
    }
    return exception is http.ClientException || exception is SocketException;
  }

  Future<void> _run(Downloader downloader, DownloadJob job) async {
    try {
      final result = await downloader.downloadTrack(
        job.track,
        await destination(),
        quality: quality,
        folderTemplate: folderTemplate,
        fileTemplate: fileTemplate,
        cancellation: job.cancellation,
        onProgress: (progress) {
          final previous = job.progress;
          job.progress = progress;

          // Recorded on every callback, before the publish throttle: the
          // meter needs all the bytes, the UI only needs some of the frames.
          _throughput.record(
            progress.bytes - (previous?.bytes ?? 0),
            DateTime.now(),
          );

          if (_shouldPublishProgress(previous, progress)) {
            _notifyProgress();
          }
        },
      );
      job.path = result.path;
      job.remuxed = result.remuxed;
      job.isSample = result.isSample;
      job.sampleReason = result.sampleReason;

      if (Platform.isAndroid) {
        final name = result.path.split(Platform.pathSeparator).last;
        final published = await MediaStore.publishAudio(
          sourcePath: result.path,
          displayName: name,
        );
        if (published != null) {
          await File(result.path).delete().catchError((_) => File(result.path));
          job.path = published;
        }
      }

      _setStatus(job, JobStatus.completed);
      _recordHistory(
        job.track,
        job.path!,
        result.isSample
            ? 'Sample MP3 (${result.sampleReason ?? 'full track unavailable'})'
            : quality.label,
      );
    } on DownloadCancelled {
      _setStatus(job, JobStatus.cancelled);
    } on Object catch (exception) {
      job.error = exception.toString();
      if (job.attempts < maxJobAttempts &&
          !job.cancellation.isCancelled &&
          _isTransient(exception)) {
        job.progress = null;
        _setStatus(job, JobStatus.queued);
        _scheduleRetry(job);
      } else {
        _setStatus(job, JobStatus.failed);
      }
    } finally {
      _running -= 1;
      _notify();
      unawaited(_pump());
    }
  }

  /// Flushes state and stops the engine ahead of a window close.
  ///
  /// The queue file is written first, while running jobs still hold their
  /// honest status, so anything in flight restores as queued next start.
  /// Only then does the downloader close, which kills the transfer isolates
  /// and quiets the disk at once. History goes last so it includes whatever
  /// completed while the queue was being written. Each flush is skipped when
  /// nothing changed, so an idle app still closes instantly.
  Future<void> prepareForExit() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _discovery?.cancel();

    _queueFlush?.cancel();
    if (_queueDirty || _queueStale || _queueSaving) {
      await saveQueue();
      await _saveIdle(() => _queueSaving);
    }

    _downloader?.close();

    _historyFlush?.cancel();
    if (_historyDirty || _historySaving) {
      await _saveHistory();
      await _saveIdle(() => _historySaving);
    }
  }

  /// Waits out a save already in flight. The coalescing savers deliberately
  /// return early when one is running; everywhere else that is the right
  /// call, but the exit path must see the bytes actually on disk.
  Future<void> _saveIdle(bool Function() busy) async {
    while (busy()) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();

    if (_historyDirty || (_historyFlush?.isActive ?? false)) {
      unawaited(_saveHistory());
    }
    _historyFlush?.cancel();

    // Best-effort final flush. It may not finish if the process is going
    // away, which costs at most the last few seconds of queue changes, or
    // for a merely stale file some entries the next restore skips anyway.
    if (_queueDirty || _queueStale) unawaited(saveQueue());
    _queueFlush?.cancel();

    for (final job in _jobs) {
      job.cancellation.cancel();
    }
    _downloader?.close();
    ffmpeg.close();
    super.dispose();
  }
}
