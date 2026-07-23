/// Preview playback.
///
/// Plays the catalog's HLS stream directly. The player handles the AES-128
/// decryption itself, so previewing does not go through the download pipeline
/// and nothing is written to disk.
library;

import 'dart:async';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
// media_kit exports its own Track, meaning an audio stream within a media file.
// Only the two types actually used are imported so it cannot shadow the
// catalog's Track.
import 'package:media_kit/media_kit.dart' show Media, Player;

import '../engine/catalog.dart';
import '../engine/download.dart';
import '../engine/errors.dart';
import '../engine/hls.dart';
import '../engine/models.dart';

/// Turns an internal error into something worth reading.
///
/// A 404 here is not a fault of ours: Beatport hands out a stream link for
/// some tracks whose HLS asset does not actually exist, so the playlist or its
/// segments come back missing. Say that plainly rather than a raw status code.
String previewErrorMessage(Object exception) {
  if (exception is BeatportException) {
    if (exception.status == 404 || exception.status == 403) {
      return 'No preview available for this track.';
    }
    return 'Preview unavailable (${exception.status}).';
  }
  if (exception is HlsException) {
    return 'No preview available for this track.';
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
        // Roll on to the next track in the list when autoplay is on, so a set
        // can be auditioned hands-free; otherwise just clear the transport.
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

  /// Segments to fetch, or null for the whole track.
  ///
  /// The whole track by default: a 30 second clip is not enough to judge a
  /// transition, and the fetch is a few seconds because segments are pulled in
  /// parallel and cached afterwards.
  int? previewSegments;

  /// How far the preview fetch has got, while loading.
  double loadProgress = 0;

  /// Whether a finished preview rolls on to the next track in the list.
  bool _autoplay = true;
  bool get autoplay => _autoplay;
  set autoplay(bool value) {
    _autoplay = value;
    _notify();
  }

  /// The list autoplay steps through, set when playback starts so "next"
  /// follows the list the user played from. [_upNextFiles] maps a track id to a
  /// local file path when the list is downloaded tracks, so autoplay plays the
  /// file rather than streaming a preview.
  List<Track> _upNext = const [];
  Map<int, String> _upNextFiles = const {};
  void setUpNext(List<Track> tracks, {Map<int, String> files = const {}}) {
    _upNext = tracks;
    _upNextFiles = files;
  }

  /// The track after [track] in [_upNext], or null at the end of the list.
  Track? _nextAfter(Track track) {
    final index = _upNext.indexWhere((t) => t.id == track.id);
    if (index < 0 || index + 1 >= _upNext.length) return null;
    return _upNext[index + 1];
  }

  /// Plays [track] the way its list plays it: a downloaded file when one is
  /// known for it, otherwise a streamed preview.
  Future<void> _playInList(Track track) {
    final path = _upNextFiles[track.id];
    return path != null ? playLocal(track, path) : toggle(track);
  }

  /// The track being previewed, if any.
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

  bool isCurrent(Track track) => current?.id != null && current?.id == track.id;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Starts [track], or pauses it when it is already playing.
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
    error = null;
    position = Duration.zero;
    duration = Duration.zero;
    _notify();

    try {
      final downloader = _downloader;
      if (downloader == null) throw StateError('player is not bound');

      final directory = await _cacheDirectory();
      final cached = File('${directory.path}${Platform.pathSeparator}$id.aac');
      // Re-previewing a track should not re-fetch it.
      final file = await cached.exists()
          ? cached
          : await downloader.downloadPreview(
              id,
              directory,
              segments: previewSegments,
              onProgress: (progress) {
                // A newer request may already own the player.
                if (current?.id != id) return;
                loadProgress = progress.fraction;
                _notify();
              },
            );

      // A newer request may have started while this one was in flight.
      if (current?.id != id) return;
      await _player.open(Media(file.path));
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

  /// Plays a downloaded file from [path], or pauses it when it is already
  /// playing. Unlike [toggle] there is nothing to fetch: the file is on disk.
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

  /// Total size of the cached previews, in bytes.
  Future<int> cacheSize() async {
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Removes cached preview audio.
  ///
  /// Stops playback first: the current track's file is in the cache and
  /// deleting it from under the player would leave it reading a missing file.
  Future<void> clearCache() async {
    await stop();
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return;
    await directory.delete(recursive: true).catchError((_) => directory);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _downloader?.close();
    _player.dispose();
    super.dispose();
  }
}
