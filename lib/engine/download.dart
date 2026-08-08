library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'catalog.dart';
import 'decrypt_pool.dart';
import 'errors.dart';
import 'ffmpeg.dart';
import 'hls.dart';
import 'models.dart';
import 'naming.dart';
import 'request_limiter.dart';

enum AudioQuality {
  lossless('lossless', 'FLAC'),

  high('high', 'AAC 256 kbps'),

  medium('medium', 'AAC 128 kbps'),

  hls('medium-hls', 'AAC 128 kbps (stream)');

  const AudioQuality(this.value, this.label);

  final String value;
  final String label;

  bool get usesStream => this == AudioQuality.hls;
}

const String defaultFileTemplate = '{artists} - {title}';

const int segmentWindow = 6;

/// Segment fetches allowed across all downloads at once.
///
/// [segmentWindow] is per track, so at high concurrency the totals stop making
/// sense: sixty-four tracks would put nearly four hundred requests in flight
/// and hold every one of their bodies in memory at the same time. This caps
/// the whole app regardless of how many tracks are running.
const int totalSegmentWindow = 24;

/// Remuxes allowed at once.
///
/// Each one spawns an ffmpeg process, which is expensive to create, more so on
/// Windows. A queue of short tracks finishes them in bursts, so without a cap
/// the app spends its time spawning processes. The work itself is a stream
/// copy, so a small number keeps up easily.
const int maxParallelRemux = 3;

/// Consecutive refusals from the download endpoint before the downloader stops
/// asking. An account without download entitlement refuses every track, and
/// that doomed request doubles the API round-trips each track needs.
const int entitlementRefusalLimit = 5;

/// How often to try the download endpoint again after giving up on it, in
/// tracks, so a subscription that starts working is picked up.
const int entitlementRecheckInterval = 100;

final RegExp _illegalPathChars = RegExp(r'[<>:"|?*\\/\x00-\x1f]');
final RegExp _whitespaceRun = RegExp(r'\s+');

const int maxFileNameLength = 180;

String sanitizeFileName(String name) {
  var cleaned = name
      .replaceAll(_illegalPathChars, '')
      .replaceAll(_whitespaceRun, ' ')
      .trim();

  cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
  if (cleaned.length > maxFileNameLength) {
    cleaned = cleaned.substring(0, maxFileNameLength).trim();
  }
  return cleaned.isEmpty ? 'track' : cleaned;
}

class DownloadProgress {
  const DownloadProgress({
    required this.completed,
    required this.total,
    required this.bytes,
    this.segmented = false,
  });

  final int completed;
  final int total;
  final int bytes;

  final bool segmented;

  double get fraction => total == 0 ? 0 : completed / total;
}

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

class PreviewResult {
  const PreviewResult({
    required this.file,
    required this.isSample,
    this.sampleReason,
  });

  final File file;

  final bool isSample;

  final String? sampleReason;
}

String previewFileName(int trackId, {required bool sample}) =>
    '$trackId${sample ? '.mp3' : '.aac'}';

/// Turns a refusal from the download/stream endpoints into a short, readable
/// reason to show the user instead of the raw HTTP status.
String sampleReasonFrom(BeatportException? refusal) {
  if (refusal == null) return 'full track unavailable';
  final message = refusal.message.toLowerCase();
  if (refusal.status == 403 &&
      (message.contains('subscription') || message.contains('permission'))) {
    return 'no active Beatport subscription';
  }
  if (refusal.status == 403) return 'account not entitled to this track';
  if (refusal.status == 404) return 'track unavailable at this quality';
  return 'full track unavailable (HTTP ${refusal.status})';
}

class DownloadResult {
  const DownloadResult({
    required this.path,
    required this.remuxed,
    this.isSample = false,
    this.sampleReason,
  });

  final String path;

  final bool remuxed;

  final bool isSample;

  /// Why a sample was written instead of the full track, e.g. because the
  /// account has no active subscription. Null unless [isSample] is true.
  final String? sampleReason;
}

class Downloader {
  Downloader({
    required this.catalog,
    http.Client? httpClient,
    Ffmpeg? ffmpeg,
    DecryptPool? decryptPool,
    this.segmentConcurrency = segmentWindow,
    int totalSegments = totalSegmentWindow,
    int parallelRemux = maxParallelRemux,
  }) : _http = httpClient ?? http.Client(),
       ffmpeg = ffmpeg ?? Ffmpeg(),
       decrypt = decryptPool ?? DecryptPool(),
       _segments = RequestLimiter(totalSegments),
       _remuxes = RequestLimiter(parallelRemux);

  /// Caps segment fetches across every download at once, so raising the track
  /// concurrency does not multiply the requests and buffers in flight.
  final RequestLimiter _segments;

  /// Caps concurrent ffmpeg processes.
  final RequestLimiter _remuxes;

  /// Set once the account has refused enough downloads that asking again is
  /// clearly wasted. Rechecked periodically in case entitlement changes.
  int _entitlementRefusals = 0;
  int _sinceEntitlementCheck = 0;

  bool get _skipDirectDownload =>
      _entitlementRefusals >= entitlementRefusalLimit &&
      _sinceEntitlementCheck < entitlementRecheckInterval;

  final Catalog catalog;
  final http.Client _http;
  final Ffmpeg ffmpeg;

  /// Shared across every download this downloader runs, so the isolates are
  /// spawned once rather than per segment.
  final DecryptPool decrypt;

  final int segmentConcurrency;

  void close() {
    _http.close();
    decrypt.close();
  }

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
    BeatportException? refusal;

    // An account without download entitlement refuses every single track, and
    // that refusal costs a round-trip each time. Once it has said no often
    // enough, stop asking and go straight to the stream; try again every so
    // often so an upgraded subscription is noticed.
    if (_skipDirectDownload) {
      _sinceEntitlementCheck += 1;
      refusal = BeatportException(
        403,
        'account has no download entitlement for this quality',
      );
    } else if (!quality.usesStream) {
      _sinceEntitlementCheck = 0;
      try {
        final result = await _downloadDirect(
          id,
          quality,
          directory,
          baseName,
          onProgress: onProgress,
          cancellation: cancellation,
        );
        _entitlementRefusals = 0;
        return result;
      } on BeatportException catch (exception) {
        refusal = exception;
        if (exception.status == 403) {
          _entitlementRefusals += 1;
        } else {
          _entitlementRefusals = 0;
        }
      }
    }

    try {
      final stream = await catalog.trackStream(id);
      if (stream.url.isEmpty) {
        if (refusal != null) throw refusal;
        throw BeatportException(404, 'no stream published for track $id');
      }
      return await downloadStream(
        Uri.parse(stream.url),
        directory,
        baseName,
        track: track,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    } on BeatportException catch (exception) {
      if (exception.status != 403 && exception.status != 404) rethrow;
      refusal ??= exception;
    }

    final sampleUrl = track.sampleUrl;
    if (sampleUrl != null && sampleUrl.isNotEmpty) {
      return _downloadSampleTrack(
        id,
        sampleUrl,
        directory,
        baseName,
        reason: sampleReasonFrom(refusal),
        onProgress: onProgress,
        cancellation: cancellation,
      );
    }
    throw refusal;
  }

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
      final reason = response.reasonPhrase?.trim() ?? '';
      throw BeatportException(
        response.statusCode,
        reason.isEmpty ? 'download failed' : 'download failed: $reason',
      );
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

    return DownloadResult(path: target.path, remuxed: true);
  }

  Future<DownloadResult> downloadStream(
    Uri streamUrl,
    Directory directory,
    String baseName, {
    Track? track,
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

      final window = segmentConcurrency < 1 ? 1 : segmentConcurrency;
      for (var start = 0; start < segments.length; start += window) {
        cancellation?.throwIfCancelled();
        final end = math.min(start + window, segments.length);

        final batch = await Future.wait([
          for (var i = start; i < end; i++) _fetchSegment(segments[i], i, key),
        ]);

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
    await _remux(tool, transport, output, track: track);
    await transport.delete().catchError((_) => transport);
    return DownloadResult(path: output.path, remuxed: true);
  }

  Directory _resolveDirectory(Directory base, Track track, String template) {
    final segments = folderSegments(template, track);
    if (segments.isEmpty) return base;
    return Directory([base.path, ...segments].join(Platform.pathSeparator));
  }

  Future<PreviewResult> downloadPreview(
    int trackId,
    Directory directory, {
    int? segments,
    String? sampleUrl,
    void Function(DownloadProgress)? onProgress,
    Cancellation? cancellation,
  }) async {
    String? streamUrl;
    BeatportException? refusal;
    try {
      final stream = await catalog.trackStream(trackId);
      if (stream.url.isNotEmpty) {
        streamUrl = stream.url;
      } else {
        refusal = BeatportException(
          404,
          'no stream published for track $trackId',
        );
      }
    } on BeatportException catch (exception) {
      if (exception.status != 403 && exception.status != 404) rethrow;
      refusal = exception;
    }

    if (streamUrl == null) {
      if (sampleUrl == null || sampleUrl.isEmpty) throw refusal!;
      return _downloadSample(
        trackId,
        sampleUrl,
        directory,
        reason: sampleReasonFrom(refusal),
        onProgress: onProgress,
        cancellation: cancellation,
      );
    }

    final (playlist, key) = await loadStream(
      Uri.parse(streamUrl),
      httpClient: _http,
    );
    cancellation?.throwIfCancelled();

    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}'
      '${previewFileName(trackId, sample: false)}',
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
    return PreviewResult(file: target, isSample: false);
  }

  Future<PreviewResult> _downloadSample(
    int trackId,
    String sampleUrl,
    Directory directory, {
    String? reason,
    void Function(DownloadProgress)? onProgress,
    Cancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}'
      '${previewFileName(trackId, sample: true)}',
    );

    final response = await _http.send(
      http.Request('GET', Uri.parse(sampleUrl)),
    );
    if (response.statusCode != 200) {
      throw BeatportException(
        response.statusCode,
        'could not read the sample for track $trackId',
      );
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

    return PreviewResult(file: target, isSample: true, sampleReason: reason);
  }

  Future<DownloadResult> _downloadSampleTrack(
    int trackId,
    String sampleUrl,
    Directory directory,
    String baseName, {
    String? reason,
    void Function(DownloadProgress)? onProgress,
    Cancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}$baseName.mp3',
    );

    final response = await _http.send(
      http.Request('GET', Uri.parse(sampleUrl)),
    );
    if (response.statusCode != 200) {
      throw BeatportException(
        response.statusCode,
        'could not read the sample for track $trackId',
      );
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
    return DownloadResult(
      path: target.path,
      remuxed: true,
      isSample: true,
      sampleReason: reason,
    );
  }

  Future<Uint8List> _fetchSegment(Uri url, int index, StreamKey? key) async {
    // Gated app-wide, not per track: the body of every segment in flight is
    // held in memory until it is decrypted and written.
    final response = await _segments.run(() => _http.get(url));
    if (response.statusCode != 200) {
      throw BeatportException(
        response.statusCode,
        'segment ${index + 1} failed',
      );
    }

    // bodyBytes is already a Uint8List; copying it again just to hand it on
    // is pure waste at this volume.
    final payload = response.bodyBytes;
    if (key == null) return payload;

    // AES-CBC decryption is pure CPU work with no natural await point, so it
    // cannot run on the UI isolate. It goes to a standing pool rather than a
    // fresh isolate per segment: at this concurrency the spawning alone was
    // enough to stall the app.
    return decrypt.decrypt(payload, key);
  }

  Future<void> _remux(String tool, File input, File output, {Track? track}) =>
      _remuxes.run(() => _runRemux(tool, input, output, track: track));

  Future<void> _runRemux(
    String tool,
    File input,
    File output, {
    Track? track,
  }) async {
    final result = await Process.run(tool, [
      '-y',
      '-i',
      input.path,
      '-map_metadata',
      '-1',
      ..._metadataArgs(track),
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

  /// Builds ffmpeg `-metadata` flags so DJ software (rekordbox, Serato,
  /// Traktor) sees title/artist/genre/BPM/key without relying on the
  /// filename. `-map_metadata -1` above drops whatever the HLS segments
  /// carried; these flags then set only the fields we trust from the
  /// catalog response.
  List<String> _metadataArgs(Track? track) {
    if (track == null) return const [];
    final values = templateValues(track);
    final comment = [
      if (values['key']!.isNotEmpty) 'Key: ${values['key']}',
      if (values['bpm']!.isNotEmpty) 'BPM: ${values['bpm']}',
    ].join(' | ');

    void addIfPresent(List<String> args, String key, String? value) {
      if (value != null && value.isNotEmpty) {
        args.addAll(['-metadata', '$key=$value']);
      }
    }

    final args = <String>[];
    addIfPresent(args, 'title', values['title']);
    addIfPresent(args, 'artist', values['artists']);
    addIfPresent(args, 'album', values['label']);
    addIfPresent(
      args,
      'genre',
      values['subgenre']!.isNotEmpty ? values['subgenre'] : values['genre'],
    );
    addIfPresent(args, 'date', values['year']);
    addIfPresent(args, 'comment', comment.isEmpty ? null : comment);
    return args;
  }
}
