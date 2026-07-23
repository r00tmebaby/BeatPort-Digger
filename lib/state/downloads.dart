/// The download queue shared by every screen.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/catalog.dart';
import '../engine/download.dart';
import '../engine/download_history.dart';
import '../engine/ffmpeg.dart';
import '../engine/media_store.dart';
import '../engine/models.dart';

enum JobStatus { queued, running, completed, failed, cancelled }

class DownloadJob {
  DownloadJob(this.track);

  final Track track;
  final Cancellation cancellation = Cancellation();

  JobStatus status = JobStatus.queued;
  DownloadProgress? progress;
  String? path;
  String? error;

  /// False when the file was left as MPEG-TS because ffmpeg was unavailable.
  bool remuxed = true;

  bool get isFinished =>
      status == JobStatus.completed ||
      status == JobStatus.failed ||
      status == JobStatus.cancelled;
}

/// Runs downloads a few at a time and reports their state to the UI.
class DownloadQueue extends ChangeNotifier {
  DownloadQueue({int maxConcurrent = 4}) : _maxConcurrent = maxConcurrent;

  int _maxConcurrent;

  /// How many tracks download at once.
  ///
  /// Four is the starting point because each track also fetches its segments in
  /// parallel, so the open connection count is the product of the two.
  int get maxConcurrent => _maxConcurrent;

  set maxConcurrent(int value) {
    final clamped = value.clamp(1, 16);
    if (clamped == _maxConcurrent) return;
    _maxConcurrent = clamped;
    _notify();
    unawaited(saveSettings());
    // Raising the limit should start queued work straight away.
    unawaited(_pump());
  }

  final Ffmpeg ffmpeg = Ffmpeg();

  /// Quality requested for new downloads. Lossless by default: it is what the
  /// download endpoint serves when the account allows it, and costs nothing
  /// extra to ask for.
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

  /// A download in flight outlives the queue on sign-out or shutdown, and
  /// ChangeNotifier throws if notified after disposal.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  final List<DownloadJob> _jobs = [];

  /// Jobs by track id, kept in step with [_jobs] for O(1) lookup.
  final Map<int, DownloadJob> _byId = {};

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);

  // Persistent history of past downloads, by track id.
  final Map<int, HistoryEntry> _history = {};
  Timer? _historyFlush;

  List<HistoryEntry> get history =>
      _history.values.toList()
        ..sort((a, b) => b.completedAt.compareTo(a.completedAt));

  int get historyCount => _history.length;
  int get missingCount => _history.values.where((e) => !e.present).length;

  /// How a track stands relative to past downloads, for the results list.
  HistoryMark historyMark(Track track) {
    final id = track.id;
    if (id == null) return HistoryMark.none;
    final entry = _history[id];
    if (entry == null) return HistoryMark.none;
    return entry.present ? HistoryMark.saved : HistoryMark.missing;
  }

  HistoryEntry? historyEntry(int trackId) => _history[trackId];

  void _recordHistory(Track track, String path) {
    final id = track.id;
    if (id == null) return;
    _history[id] = HistoryEntry(
      trackId: id,
      title: track.title,
      artists: track.artistNames,
      path: path,
      quality: quality.label,
      completedAt: _now(),
      present: true,
    );
    _scheduleHistorySave();
  }

  /// Passed timestamps come from the caller; Date.now is unavailable in some
  /// contexts, but the queue runs on the UI isolate where it is fine.
  DateTime _now() => DateTime.now();

  bool get isBusy => _jobs.any((job) => !job.isFinished);
  int get activeCount => _jobs.where((job) => !job.isFinished).length;

  // ffmpeg install state, surfaced so the UI can offer to fetch it.
  bool _ffmpegReady = false;
  bool _ffmpegChecked = false;
  bool installing = false;
  InstallProgress? installProgress;
  String? installError;

  bool get ffmpegReady => _ffmpegReady;
  bool get ffmpegChecked => _ffmpegChecked;
  bool get canInstallFfmpeg => ffmpeg.canInstall;

  /// Binds the queue to the signed-in session's catalog.
  void bind(Catalog catalog) {
    if (_downloader?.catalog == catalog) return;
    _downloader?.close();
    _downloader = Downloader(catalog: catalog, ffmpeg: ffmpeg);
  }

  /// Checks for ffmpeg once, so the UI can prompt before anything is queued.
  Future<void> checkFfmpeg() async {
    if (_ffmpegChecked) return;
    _ffmpegReady = await ffmpeg.resolve() != null;
    _ffmpegChecked = true;
    _notify();
  }

  /// Downloads and installs the pinned ffmpeg build.
  Future<bool> installFfmpeg() async {
    if (installing) return false;
    installing = true;
    installError = null;
    installProgress = null;
    _notify();

    try {
      await ffmpeg.install(onProgress: (progress) {
        installProgress = progress;
        _notify();
      });
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

  /// An explicit download folder, or null to use the default location.
  String? destinationOverride;

  /// Tint track rows by download state.
  bool colourByStatus = true;

  set statusColours(bool value) {
    if (colourByStatus == value) return;
    colourByStatus = value;
    _notify();
    unawaited(saveSettings());
  }

  /// Sub-folder layout beneath the download folder. Empty means flat.
  String folderTemplate = '';

  /// File name layout, without the extension.
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

  /// The folder downloads are written to, as text, for display.
  Future<String> destinationPath() async => (await destination()).path;

  /// Where finished files are written.
  Future<Directory> destination() async {
    final override = destinationOverride;
    if (override != null && override.isNotEmpty) return Directory(override);
    if (_destination != null) return _destination!;
    final base = Platform.isAndroid || Platform.isIOS
        ? await getApplicationDocumentsDirectory()
        : await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
    return _destination =
        Directory('${base.path}${Platform.pathSeparator}Beatport');
  }

  Future<void> setDestination(String? path) async {
    destinationOverride = path;
    _notify();
    await saveSettings();
  }

  // -- persistence ------------------------------------------------------

  Future<File> _settingsFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}${Platform.pathSeparator}download_settings.json');
  }

  /// Restores saved preferences. Failures are ignored: defaults are usable.
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
      if (concurrent is int) _maxConcurrent = concurrent.clamp(1, 16);
      final folder = payload['destination'];
      if (folder is String && folder.isNotEmpty) destinationOverride = folder;
      final folders = payload['folder_template'];
      if (folders is String) folderTemplate = folders;
      final files = payload['file_template'];
      if (files is String && files.trim().isNotEmpty) fileTemplate = files;
      final colours = payload['status_colours'];
      if (colours is bool) colourByStatus = colours;

      _notify();
    } on Object {
      // A corrupt or unreadable settings file should not stop the app.
    }
  }

  Future<void> saveSettings() async {
    try {
      final file = await _settingsFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'quality': quality.value,
          'max_concurrent': _maxConcurrent,
          'folder_template': folderTemplate,
          'file_template': fileTemplate,
          'status_colours': colourByStatus,
          if (destinationOverride != null) 'destination': destinationOverride,
        }),
      );
    } on Object {
      // Losing a preference is not worth surfacing an error for.
    }
  }

  // -- history ----------------------------------------------------------

  Future<File> _historyFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}${Platform.pathSeparator}download_history.json');
  }

  /// Loads past downloads, then checks in the background whether their files
  /// still exist so the results list can flag any that were deleted.
  Future<void> loadHistory() async {
    try {
      final file = await _historyFile();
      if (await file.exists()) {
        final payload = jsonDecode(await file.readAsString());
        if (payload is List) {
          for (final raw in payload.whereType<Map<String, dynamic>>()) {
            final entry = HistoryEntry.fromJson(raw);
            if (entry != null) _history[entry.trackId] = entry;
          }
        }
      }
      _notify();
    } on Object {
      // A corrupt history is not fatal; start empty.
    }
    unawaited(verifyHistory());
  }

  /// Marks entries whose file is no longer on disk, without dropping them.
  Future<void> verifyHistory() async {
    if (_history.isEmpty) return;
    var changed = false;
    for (final entry in _history.values.toList()) {
      final present = await File(entry.path).exists();
      // Re-check membership after the await: the entry may have been cleared
      // while the disk check was in flight, and reassigning would resurrect it.
      if (!_history.containsKey(entry.trackId)) continue;
      if (present != entry.present) {
        _history[entry.trackId] = entry.copyWith(present: present);
        changed = true;
      }
    }
    if (changed) {
      _notify();
      _scheduleHistorySave();
    }
  }

  /// Drops entries whose file is gone.
  Future<void> removeMissingHistory() async {
    _history.removeWhere((_, entry) => !entry.present);
    _notify();
    await _saveHistory();
  }

  Future<void> clearHistory() async {
    _history.clear();
    _notify();
    await _saveHistory();
  }

  /// Batches writes: a large batch completing would otherwise rewrite the whole
  /// file per track.
  void _scheduleHistorySave() {
    _historyFlush?.cancel();
    _historyFlush = Timer(const Duration(milliseconds: 500), _saveHistory);
    _notify();
  }

  Future<void> _saveHistory() async {
    _historyFlush?.cancel();
    try {
      final file = await _historyFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode([for (final e in _history.values) e.toJson()]),
      );
    } on Object {
      // Losing history is not worth surfacing an error for.
    }
  }

  /// The job for a track, if it has been queued this session.
  ///
  /// Indexed rather than scanned: the track list asks this for every visible
  /// row on every rebuild, so a linear search here is quadratic on screen.
  DownloadJob? jobFor(Track track) {
    final id = track.id;
    return id == null ? null : _byId[id];
  }

  /// Adds one track without notifying, so a bulk add can notify once.
  ///
  /// Returns whether a job was actually created.
  bool _add(Track track) {
    final id = track.id;
    if (id == null) return false;

    final existing = _byId[id];
    // A failed or cancelled job may be retried; a live one is not re-queued,
    // which would write the same file twice concurrently.
    if (existing != null && !_isRetryable(existing)) return false;
    if (existing != null) _jobs.remove(existing);

    final job = DownloadJob(track);
    _jobs.add(job);
    _byId[id] = job;
    return true;
  }

  /// Queues a track, ignoring one already queued or downloaded.
  void enqueue(Track track) {
    if (!_add(track)) return;
    _notify();
    unawaited(_pump());
  }

  bool _isRetryable(DownloadJob job) =>
      job.status == JobStatus.failed || job.status == JobStatus.cancelled;

  /// Queues many tracks at once, returning how many were actually added.
  ///
  /// Notifies once at the end. Notifying per track rebuilt the whole list for
  /// every addition, which froze the UI on a select-all of any size.
  int enqueueAll(Iterable<Track> tracks) {
    var added = 0;
    for (final track in tracks) {
      if (_add(track)) added += 1;
    }
    if (added > 0) {
      _notify();
      unawaited(_pump());
    }
    return added;
  }

  // Streaming discovery, for queueing everything behind a filter or a link.
  bool discovering = false;
  int discovered = 0;
  String? discoverLabel;
  String? discoverError;
  Cancellation? _discovery;

  bool get isDiscovering => discovering;

  void cancelDiscovery() {
    _discovery?.cancel();
    _notify();
  }

  /// Queues every track from [source] as it is found.
  ///
  /// Enumerating a broad filter takes many requests, so tracks are queued as
  /// they arrive rather than after the walk finishes: downloading starts
  /// immediately and a cancel does not throw away what was already found.
  Future<int> enqueueStream(Stream<Track> source, {required String label}) async {
    if (discovering) return 0;
    final cancellation = Cancellation();
    _discovery = cancellation;
    discovering = true;
    discovered = 0;
    discoverLabel = label;
    discoverError = null;
    _notify();

    try {
      var sinceNotify = 0;
      await for (final track in source) {
        if (cancellation.isCancelled) break;
        if (_add(track)) {
          discovered += 1;
          sinceNotify += 1;
        }
        // Rebuilding the list for every track found is what makes a broad walk
        // crawl. Batch the notifications and start the queue moving.
        if (sinceNotify >= 25) {
          sinceNotify = 0;
          _notify();
          unawaited(_pump());
        }
      }
      unawaited(_pump());
    } on Object catch (exception) {
      discoverError = exception.toString();
    } finally {
      discovering = false;
      _discovery = null;
      _notify();
    }
    return discovered;
  }

  void cancel(DownloadJob job) {
    if (job.isFinished) return;
    job.cancellation.cancel();
    if (job.status == JobStatus.queued) {
      job.status = JobStatus.cancelled;
    }
    _notify();
    unawaited(_pump());
  }

  void clearFinished() {
    _jobs.removeWhere((job) {
      if (!job.isFinished) return false;
      _byId.remove(job.track.id);
      return true;
    });
    _notify();
  }

  /// Cancels everything queued or running, and stops any discovery in flight.
  ///
  /// Discovery is stopped first: leaving it running would keep feeding new jobs
  /// into a queue the user just asked to stop.
  void cancelAll() {
    _discovery?.cancel();
    for (final job in _jobs) {
      if (job.isFinished) continue;
      job.cancellation.cancel();
      if (job.status == JobStatus.queued) job.status = JobStatus.cancelled;
    }
    _notify();
  }

  /// Cancels everything and empties the list.
  void clearAll() {
    cancelAll();
    _jobs.removeWhere((job) {
      if (!job.isFinished) return false;
      _byId.remove(job.track.id);
      return true;
    });
    _notify();
  }

  /// Starts queued jobs up to the concurrency limit.
  Future<void> _pump() async {
    final downloader = _downloader;
    if (downloader == null) return;

    while (_running < maxConcurrent) {
      DownloadJob? next;
      for (final job in _jobs) {
        if (job.status == JobStatus.queued) {
          next = job;
          break;
        }
      }
      if (next == null) return;

      _running += 1;
      next.status = JobStatus.running;
      _notify();
      unawaited(_run(downloader, next));
    }
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
          job.progress = progress;
          _notify();
        },
      );
      job.status = JobStatus.completed;
      job.path = result.path;
      job.remuxed = result.remuxed;

      // On Android, move the file into the shared Music/BeatPort Digger folder so
      // the Files app and other apps (DJ software) can see it. Playback then
      // uses the public path returned; the private copy is removed.
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

      _recordHistory(job.track, job.path!);
    } on DownloadCancelled {
      job.status = JobStatus.cancelled;
    } on Object catch (exception) {
      job.status = JobStatus.failed;
      job.error = exception.toString();
    } finally {
      _running -= 1;
      _notify();
      unawaited(_pump());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Flush any batched history write before going away.
    if (_historyFlush?.isActive ?? false) unawaited(_saveHistory());
    _historyFlush?.cancel();
    for (final job in _jobs) {
      job.cancellation.cancel();
    }
    _downloader?.close();
    ffmpeg.close();
    super.dispose();
  }
}
