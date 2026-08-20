library;

import 'dart:async';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:media_kit/media_kit.dart' show Media, Player;

import '../engine/catalog.dart';
import '../engine/download.dart';
import '../engine/errors.dart';
import '../engine/hls.dart';
import '../engine/models.dart';

String previewErrorMessage(Object exception) {
  if (exception is BeatportException) {
    return switch (exception.status) {
      404 => 'No preview available for this track.',
      401 => 'Session expired. Sign in again.',
      403 when exception.message.isNotEmpty =>
        'Beatport refused this preview: ${exception.message}',
      403 => 'Beatport refused this preview (403).',
      _ => 'Preview unavailable (${exception.status}).',
    };
  }
  if (exception is HlsException) {
    return 'The preview stream could not be read.';
  }
  return 'Could not play a preview of this track.';
}

class PreviewPlayer extends ChangeNotifier {
  PreviewPlayer() {
    _player = Player();
    _subscriptions.addAll([
      _player.stream.playing.listen((value) {
        playing = value;
        _notify();
      }),
      _player.stream.position.listen((value) {
        position = value;
        _notify();
      }),
      _player.stream.duration.listen((value) {
        duration = value;
        _notify();
      }),
      _player.stream.error.listen((value) {
        error = value;
        loading = false;
        _notify();
      }),
      _player.stream.completed.listen((value) {
        if (!value) return;

        final finished = current;
        if (_autoplay && finished != null) {
          final next = _nextAfter(finished);
          if (next != null) {
            _playInList(next);
            return;
          }
        }
        current = null;
        _notify();
      }),
    ]);
  }

  late final Player _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Catalog? _catalog;
  Downloader? _downloader;
  Directory? _cache;
  bool _disposed = false;

  int? previewSegments;

  double loadProgress = 0;

  bool isSample = false;

  bool _autoplay = true;
  bool get autoplay => _autoplay;
  set autoplay(bool value) {
    _autoplay = value;
    _notify();
  }

  List<Track> _upNext = const [];
  Map<int, String> _upNextFiles = const {};
  void setUpNext(List<Track> tracks, {Map<int, String> files = const {}}) {
    _upNext = tracks;
    _upNextFiles = files;
  }

  Track? _nextAfter(Track track) {
    final index = _upNext.indexWhere((t) => t.id == track.id);
    if (index < 0 || index + 1 >= _upNext.length) return null;
    return _upNext[index + 1];
  }

  Future<void> _playInList(Track track) {
    final path = _upNextFiles[track.id];
    return path != null ? playLocal(track, path) : toggle(track);
  }

  Track? current;
  bool playing = false;
  bool loading = false;
  String? error;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  double get progress => duration.inMilliseconds == 0
      ? 0
      : position.inMilliseconds / duration.inMilliseconds;

  void bind(Catalog catalog) {
    if (_catalog == catalog) return;
    _catalog = catalog;
    _downloader?.close();
    _downloader = Downloader(catalog: catalog);
  }

  Future<Directory> _cacheDirectory() async {
    final cached = _cache;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    return _cache = Directory(
      '${support.path}${Platform.pathSeparator}previews',
    );
  }

  Future<PreviewResult?> _cachedPreview(Directory directory, int id) async {
    for (final sample in [false, true]) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        '${previewFileName(id, sample: sample)}',
      );
      if (await file.exists()) {
        return PreviewResult(file: file, isSample: sample);
      }
    }
    return null;
  }

  bool isCurrent(Track track) => current?.id != null && current?.id == track.id;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> toggle(Track track) async {
    final catalog = _catalog;
    final id = track.id;
    if (catalog == null || id == null) return;

    if (isCurrent(track)) {
      await (playing ? _player.pause() : _player.play());
      return;
    }

    current = track;
    loading = true;
    loadProgress = 0;
    isSample = false;
    error = null;
    position = Duration.zero;
    duration = Duration.zero;
    _notify();

    try {
      final downloader = _downloader;
      if (downloader == null) throw StateError('player is not bound');

      final directory = await _cacheDirectory();

      final preview =
          await _cachedPreview(directory, id) ??
          await downloader.downloadPreview(
            id,
            directory,
            segments: previewSegments,
            sampleUrl: track.sampleUrl,
            onProgress: (progress) {
              if (current?.id != id) return;
              loadProgress = progress.fraction;
              _notify();
            },
          );

      if (current?.id != id) return;
      isSample = preview.isSample;
      await _player.open(Media(preview.file.path));
    } on Object catch (exception) {
      if (current?.id == id) {
        error = _friendlyError(exception);
        current = null;
      }
    } finally {
      if (current?.id == id) loading = false;
      _notify();
    }
  }

  Future<void> playLocal(Track track, String path) async {
    final id = track.id;
    if (id == null) return;

    if (isCurrent(track)) {
      await (playing ? _player.pause() : _player.play());
      return;
    }

    current = track;
    loading = true;
    loadProgress = 1;

    isSample = false;
    error = null;
    position = Duration.zero;
    duration = Duration.zero;
    _notify();

    try {
      if (!await File(path).exists()) {
        throw const FileSystemException('The downloaded file is missing.');
      }
      if (current?.id != id) return;
      await _player.open(Media(path));
    } on Object {
      if (current?.id == id) {
        error = 'Could not play the downloaded file.';
        current = null;
      }
    } finally {
      if (current?.id == id) loading = false;
      _notify();
    }
  }

  String _friendlyError(Object exception) => previewErrorMessage(exception);

  Future<void> stop() async {
    current = null;
    playing = false;
    isSample = false;
    position = Duration.zero;
    duration = Duration.zero;
    _notify();
    await _player.stop();
  }

  Future<void> seek(double fraction) async {
    if (duration.inMilliseconds == 0) return;
    await _player.seek(
      Duration(milliseconds: (duration.inMilliseconds * fraction).round()),
    );
  }

  Future<void> setVolume(double value) => _player.setVolume(value * 100);

  Future<int> cacheSize() async {
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<void> clearCache() async {
    await stop();
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return;
    await directory.delete(recursive: true).catchError((_) => directory);
  }

  /// Tears the native player down ahead of process exit and completes when
  /// it is actually gone. mpv keeps worker threads of its own on Windows,
  /// and a process that dies while they run is the unkillable husk that
  /// lingers in Task Manager after the window has closed.
  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _downloader?.close();
    await _player.dispose();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
