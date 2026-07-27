/// Turns a track into an audio file on disk.
///
/// Two paths exist. The download endpoint returns a pre-signed URL for a
/// finished file and is used for every quality it serves, lossless included.
/// The stream endpoint returns an HLS playlist of encrypted AAC segments, used
/// as a fallback when the download endpoint refuses a track.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'catalog.dart';
import 'errors.dart';
import 'ffmpeg.dart';
import 'hls.dart';
import 'models.dart';
import 'naming.dart';

/// A quality the catalog will deliver.
enum AudioQuality {
  /// FLAC via the download endpoint.
  lossless('lossless', 'FLAC'),

  /// 256 kbps AAC via the download endpoint.
  high('high', 'AAC 256 kbps'),

  /// 128 kbps AAC via the download endpoint.
  medium('medium', 'AAC 128 kbps'),

  /// 128 kbps AAC assembled from the encrypted HLS stream. Slower than the
  /// others and no better in quality; useful only when the download endpoint
  /// refuses a track.
  hls('medium-hls', 'AAC 128 kbps (stream)');

  const AudioQuality(this.value, this.label);

  /// The value the API expects for the quality parameter.
  final String value;
  final String label;

  bool get usesStream => this == AudioQuality.hls;
}

/// Default file name layout.
const String defaultFileTemplate = '{artists} - {title}';

/// How many HLS segments to fetch at once within a single track.
///
/// Segments are small and independent, so the limit is round-trip latency
/// rather than bandwidth. Kept modest so several tracks downloading at once do
/// not open an unreasonable number of connections between them.
const int segmentWindow = 6;

/// Characters Windows forbids in a file name, plus the separators.
final RegExp _illegalPathChars = RegExp(r'[<>:"|?*\\/\x00-\x1f]');
final RegExp _whitespaceRun = RegExp(r'\s+');

/// Longest file name to write, in characters.
///
/// Truncating by character rather than by byte keeps the result valid UTF-8;
/// a byte-wise slice could split a rune.
const int maxFileNameLength = 180;

/// Makes [name] safe to use as a file name.
String sanitizeFileName(String name) {
  var cleaned = name
      .replaceAll(_illegalPathChars, '')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  // A trailing dot or space is legal to create on Windows but cannot be opened.
  cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
  if (cleaned.length > maxFileNameLength) {
    cleaned = cleaned.substring(0, maxFileNameLength).trim();
  }
  return cleaned.isEmpty ? 'track' : cleaned;
}

/// Progress of a download, reported per segment.
class DownloadProgress {
  const DownloadProgress({
    required this.completed,
    required this.total,
    required this.bytes,
    this.segmented = false,
  });

  /// Units done so far: segments when [segmented], otherwise bytes.
  final int completed;
  final int total;
  final int bytes;

  /// True for the HLS path, where progress is counted in segments because the
  /// total byte size is not known until the last one arrives.
  final bool segmented;

  double get fraction => total == 0 ? 0 : completed / total;
}

/// Cooperative cancellation for a download in flight.
class Cancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const DownloadCancelled();
  }
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'download cancelled';
}

/// Where a finished download landed, and in what container.
class DownloadResult {
  const DownloadResult({required this.path, required this.remuxed});

  final String path;

  /// False when ffmpeg was unavailable and the MPEG-TS was kept as-is.
  final bool remuxed;
}

/// Downloads tracks over HLS.
class Downloader {
  Downloader({
    required this.catalog,
    http.Client? httpClient,
    Ffmpeg? ffmpeg,
    this.segmentConcurrency = segmentWindow,
  }) : _http = httpClient ?? http.Client(),
       ffmpeg = ffmpeg ?? Ffmpeg();

  final Catalog catalog;
  final http.Client _http;
  final Ffmpeg ffmpeg;

  /// HLS segments fetched at once. Injectable so a test can prove that a
  /// parallel fetch produces the same bytes as a sequential one.
  final int segmentConcurrency;

  void close() => _http.close();

  /// Downloads [track] into [directory] and returns where it landed.
  ///
  /// Falls back to the HLS stream when the download endpoint refuses the track,
  /// which it does for material the account cannot take at that quality.
  Future<DownloadResult> downloadTrack(
    Track track,
    Directory directory, {
    AudioQuality quality = AudioQuality.lossless,
    String folderTemplate = '',
    String fileTemplate = defaultFileTemplate,
    void Function(DownloadProgress)? onProgress,
    Cancellation? cancellation,
  }) async {
    final id = track.id;
    if (id == null) {
      throw ArgumentError('track has no id');
    }

    final target = _resolveDirectory(directory, track, folderTemplate);
    final baseName = sanitizeFileName(
      renderTemplate(fileTemplate, templateValues(track)),
    );
    directory = target;

    if (!quality.usesStream) {
      try {
        return await _downloadDirect(
          id,
          quality,
          directory,
          baseName,
          onProgress: onProgress,
          cancellation: cancellation,
        );
      } on BeatportException catch (exception) {
        // 403 and 404 mean this account cannot take the track at this quality.
        // Anything else is a real failure and should surface.
        if (exception.status != 403 && exception.status != 404) rethrow;
      }
    }

    final stream = await catalog.trackStream(id);
    if (stream.url.isEmpty) {
      throw BeatportException(404, 'no stream published for track $id');
    }
    return downloadStream(
      Uri.parse(stream.url),
      directory,
      baseName,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  /// Fetches a finished file from the pre-signed download URL.
  ///
  /// The URL carries its own authorisation, so it is requested without the
  /// bearer token.
  Future<DownloadResult> _downloadDirect(
    int trackId,
    AudioQuality quality,
    Directory directory,
    String baseName, {
    void Function(DownloadProgress)? onProgress,
    Cancellation? cancellation,
  }) async {
    final download = await catalog.trackDownload(trackId, quality.value);
    if (download.location.isEmpty) {
      throw BeatportException(404, 'no download location for track $trackId');
    }
    cancellation?.throwIfCancelled();

    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}$baseName${download.extension}',
    );

    final response = await _http.send(
      http.Request('GET', Uri.parse(download.location)),
    );
    if (response.statusCode != 200) {
      throw BeatportException(response.statusCode, 'download failed');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in response.stream) {
        cancellation?.throwIfCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          DownloadProgress(completed: received, total: total, bytes: received),
        );
      }
      await sink.flush();
      await sink.close();
    } on Object {
      await sink.close().catchError((_) {});
      await target.delete().catchError((_) => target);
      rethrow;
    }

    // Already a finished file; nothing to remux.
    return DownloadResult(path: target.path, remuxed: true);
  }

  /// Downloads an HLS stream to `<directory>/<baseName>.m4a`.
  ///
  /// Segments are raw ADTS AAC, so concatenating them yields a playable .aac
  /// file. ffmpeg only rewraps it as .m4a; without ffmpeg the .aac is kept and
  /// is still playable, unlike a bare transport stream.
  Future<DownloadResult> downloadStream(
    Uri streamUrl,
    Directory directory,
    String baseName, {
    void Function(DownloadProgress)? onProgress,
    Cancellation? cancellation,
  }) async {
    await directory.create(recursive: true);

    final (playlist, key) = await loadStream(streamUrl, httpClient: _http);
    cancellation?.throwIfCancelled();

    final transport = File(
      '${directory.path}${Platform.pathSeparator}$baseName.aac',
    );
    final sink = transport.openWrite();
    var bytes = 0;

    try {
      final segments = playlist.segments;
      var done = 0;

      // Fetched in windows rather than one at a time: a segment is only about
      // five seconds of audio, so a whole track is dozens of round trips and
      // latency dominates. Future.wait preserves order, and the window bounds
      // how much is held in memory at once.
      final window = segmentConcurrency < 1 ? 1 : segmentConcurrency;
      for (var start = 0; start < segments.length; start += window) {
        cancellation?.throwIfCancelled();
        final end = math.min(start + window, segments.length);

        final batch = await Future.wait([
          for (var i = start; i < end; i++) _fetchSegment(segments[i], i, key),
        ]);

        // Written in order, so the concatenation stays playable.
        for (final payload in batch) {
          sink.add(payload);
          bytes += payload.length;
          done += 1;
          onProgress?.call(
            DownloadProgress(
              completed: done,
              total: segments.length,
              bytes: bytes,
              segmented: true,
            ),
          );
        }
      }
      await sink.flush();
      await sink.close();
    } on Object {
      // close() must run before delete(), or the handle keeps the file locked
      // on Windows and the partial download is left behind.
      await sink.close().catchError((_) {});
      await transport.delete().catchError((_) => transport);
      rethrow;
    }

    final tool = await ffmpeg.resolve();
    if (tool == null) {
      return DownloadResult(path: transport.path, remuxed: false);
    }

    final output = File(
      '${directory.path}${Platform.pathSeparator}$baseName.m4a',
    );
    await _remux(tool, transport, output);
    await transport.delete().catchError((_) => transport);
    return DownloadResult(path: output.path, remuxed: true);
  }

  /// Applies the folder template beneath [base].
  Directory _resolveDirectory(Directory base, Track track, String template) {
    final segments = folderSegments(template, track);
    if (segments.isEmpty) return base;
    return Directory([base.path, ...segments].join(Platform.pathSeparator));
  }

  /// Writes a track to [directory] for previewing.
  ///
  /// The stream is encrypted HLS, which the audio-only libmpv build cannot
  /// demux. Decrypting it here and handing the player a plain ADTS file avoids
  /// depending on the player's format support, and reuses the same segment path
  /// the downloader is tested against.
  ///
  /// The whole track is fetched unless [segments] limits it. Segments are
  /// fetched in windows rather than all at once: a full track is dozens of
  /// requests and firing them together would open far too many connections.
  Future<File> downloadPreview(
    int trackId,
    Directory directory, {
    int? segments,
    void Function(DownloadProgress)? onProgress,
    Cancellation? cancellation,
  }) async {
    final stream = await catalog.trackStream(trackId);
    if (stream.url.isEmpty) {
      throw BeatportException(404, 'no stream published for track $trackId');
    }

    final (playlist, key) = await loadStream(
      Uri.parse(stream.url),
      httpClient: _http,
    );
    cancellation?.throwIfCancelled();

    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}$trackId.aac',
    );

    final wanted = segments == null
        ? playlist.segments.length
        : math.min(segments, playlist.segments.length);

    final sink = target.openWrite();
    var done = 0;
    var bytes = 0;
    try {
      final window = segmentConcurrency < 1 ? 1 : segmentConcurrency;
      for (var start = 0; start < wanted; start += window) {
        cancellation?.throwIfCancelled();
        final end = math.min(start + window, wanted);
        final batch = await Future.wait([
          for (var i = start; i < end; i++)
            _fetchSegment(playlist.segments[i], i, key),
        ]);
        for (final payload in batch) {
          sink.add(payload);
          bytes += payload.length;
          done += 1;
          onProgress?.call(
            DownloadProgress(
              completed: done,
              total: wanted,
              bytes: bytes,
              segmented: true,
            ),
          );
        }
      }
      await sink.flush();
      await sink.close();
    } on Object {
      await sink.close().catchError((_) {});
      await target.delete().catchError((_) => target);
      rethrow;
    }
    return target;
  }

  /// Fetches and decrypts one segment.
  Future<Uint8List> _fetchSegment(Uri url, int index, StreamKey? key) async {
    final response = await _http.get(url);
    if (response.statusCode != 200) {
      throw BeatportException(
        response.statusCode,
        'segment ${index + 1} failed',
      );
    }
    final payload = Uint8List.fromList(response.bodyBytes);
    // Every segment shares the playlist's key and IV, so they decrypt
    // independently and order only matters when writing.
    return key == null ? payload : decryptSegment(payload, key);
  }

  /// Rewraps the transport stream as .m4a without re-encoding.
  ///
  /// Source metadata is dropped: the segments carry none worth keeping, and
  /// tags are written separately.
  Future<void> _remux(String tool, File input, File output) async {
    final result = await Process.run(tool, [
      '-y',
      '-i',
      input.path,
      '-map_metadata',
      '-1',
      '-c:a',
      'copy',
      output.path,
    ]);
    if (result.exitCode != 0) {
      await output.delete().catchError((_) => output);
      final detail = result.stderr.toString().trim();
      throw Exception(
        'ffmpeg failed with exit code ${result.exitCode}'
        '${detail.isEmpty ? '' : ': ${detail.split('\n').last}'}',
      );
    }
  }
}
