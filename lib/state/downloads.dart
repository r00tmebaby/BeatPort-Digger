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

  bool remuxed = true;

  bool isSample = false;

  /// Why a sample was written instead of the full track, e.g. because the
  /// account has no active subscription. Null unless [isSample] is true.
  String? sampleReason;

  bool get isFinished =>
      status == JobStatus.completed ||
      status == JobStatus.failed ||
      status == JobStatus.cancelled;
}

class DownloadQueue extends ChangeNotifier {
  DownloadQueue({int maxConcurrent = 4}) : _maxConcurrent = maxConcurrent;

  int _maxConcurrent;

  int get maxConcurrent => _maxConcurrent;

  set maxConcurrent(int value) {
    final clamped = value.clamp(1, 16);
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

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  // Segment-level progress fires far more often than the UI needs to redraw
  // (every batch of every concurrent job); at maxConcurrent=16 that is
  // hundreds of notifyListeners() calls a second and visibly stalls the UI.
  // Progress notifications are throttled; state-changing ones (queued,
  // running, completed, failed) always go through _notify() directly.
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

  void _notifyProgress() {
    final now = DateTime.now();
    if (now.difference(_lastProgressNotify) <
        const Duration(milliseconds: 120)) {
      return;
    }
    _lastProgressNotify = now;
    _notify();
  }

  final List<DownloadJob> _jobs = [];

  final Map<int, DownloadJob> _byId = {};

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);

  final Map<int, HistoryEntry> _history = {};
  Timer? _historyFlush;

  List<HistoryEntry> get history =>
      _history.values.toList()
        ..sort((a, b) => b.completedAt.compareTo(a.completedAt));

  int get historyCount => _history.length;
  int get missingCount => _history.values.where((e) => !e.present).length;

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
    _history[id] = HistoryEntry(
      trackId: id,
      title: track.title,
      artists: track.artistNames,
      path: path,
      quality: qualityLabel,
      completedAt: _now(),
      present: true,
    );
    _scheduleHistorySave();
  }

  DateTime _now() => DateTime.now();

  bool get isBusy => _jobs.any((job) => !job.isFinished);
  int get activeCount => _jobs.where((job) => !job.isFinished).length;

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
    _downloader = Downloader(catalog: catalog, ffmpeg: ffmpeg);
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
      // Best-effort settings load; fall back to defaults on any error.
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
      // Best-effort history load; a corrupt/missing file just starts empty.
    }
    unawaited(verifyHistory());
  }

  Future<void> verifyHistory() async {
    if (_history.isEmpty) return;
    var changed = false;
    for (final entry in _history.values.toList()) {
      final present = await File(entry.path).exists();

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
      // Best-effort history save; ignore write failures (e.g. read-only fs).
    }
  }

  DownloadJob? jobFor(Track track) {
    final id = track.id;
    return id == null ? null : _byId[id];
  }

  bool _add(Track track) {
    final id = track.id;
    if (id == null) return false;

    final existing = _byId[id];

    if (existing != null && !_isRetryable(existing)) return false;
    if (existing != null) _jobs.remove(existing);

    final job = DownloadJob(track);
    _jobs.add(job);
    _byId[id] = job;
    return true;
  }

  void enqueue(Track track) {
    if (!_add(track)) return;
    _notify();
    unawaited(_pump());
  }

  bool _isRetryable(DownloadJob job) =>
      job.status == JobStatus.failed || job.status == JobStatus.cancelled;

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

  Future<int> enqueueStream(
    Stream<Track> source, {
    required String label,
  }) async {
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

  void cancelAll() {
    _discovery?.cancel();
    for (final job in _jobs) {
      if (job.isFinished) continue;
      job.cancellation.cancel();
      if (job.status == JobStatus.queued) job.status = JobStatus.cancelled;
    }
    _notify();
  }

  void clearAll() {
    cancelAll();
    _jobs.removeWhere((job) {
      if (!job.isFinished) return false;
      _byId.remove(job.track.id);
      return true;
    });
    _notify();
  }

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
          _notifyProgress();
        },
      );
      job.status = JobStatus.completed;
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

      _recordHistory(
        job.track,
        job.path!,
        result.isSample
            ? 'Sample MP3 (${result.sampleReason ?? 'full track unavailable'})'
            : quality.label,
      );
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
