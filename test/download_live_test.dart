/// End-to-end download checks against the live API.
///
/// Needs a credentials file; set BPCAT_CREDENTIALS to point at one, otherwise
/// the suite is skipped. Downloads a real track, so it is tagged live and
/// excluded from the default run.
@Tags(['live'])
library;

import 'dart:io';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/download.dart';
import 'package:beatport_digger/engine/links.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  // The downloader asks path_provider where an app-managed ffmpeg lives, which
  // needs the binding even in a plain Dart test.
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // The test binding installs HttpOverrides that answer every request with 400
  // so unit tests cannot reach the network. This suite is deliberately live.
  HttpOverrides.global = null;

  // path_provider has no platform implementation under flutter test; answer its
  // channel with a temp directory so ffmpeg resolution works.
  final pluginTemp = Directory.systemTemp.createTempSync('bpcat-support');
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => pluginTemp.path,
  );

  final credentials = Platform.environment['BPCAT_CREDENTIALS'];
  final available = credentials != null && File(credentials).existsSync();

  late http.Client client;
  late Catalog catalog;
  late Directory temp;

  setUpAll(() async {
    if (!available) return;
    client = http.Client();
    final auth = Authenticator(
      httpClient: client,
      store: FileTokenStore(credentials),
    );
    await auth.loadCached();
    catalog = Catalog(BeatportClient(auth: auth, httpClient: client));
    temp = await Directory.systemTemp.createTemp('bpcat-dl');
  });

  tearDownAll(() async {
    if (!available) return;
    client.close();
    await temp.delete(recursive: true);
  });

  test('key ids cover both enharmonic spellings of a Camelot code', () async {
    if (!available) return markTestSkipped('no credentials');
    final grouped = await catalog.keyIdsByCamelot();

    expect(grouped['8A'], isNotEmpty, reason: 'A Minor must resolve');
    // 1A is stored twice, as G# Minor and Ab Minor. Both ids must be present
    // or half the tracks in that key are invisible to the filter.
    expect(grouped['1A'], hasLength(2), reason: '1A has two spellings');
  });

  test('a multi-key filter returns tracks in every requested key', () async {
    if (!available) return markTestSkipped('no credentials');
    final grouped = await catalog.keyIdsByCamelot();
    final ids = [...?grouped['8A'], ...?grouped['8B']];

    final page = await catalog.tracks(
      TrackQuery(keyId: ids, perPage: 20),
    );
    expect(page.results, isNotEmpty);

    // The bug this guards: a comma-joined key_name returns zero results, and a
    // repeated key_name honours only the last value.
    final names = page.results.map((t) => t.key?.name).whereType<String>();
    expect(names, isNotEmpty);
    for (final name in names) {
      expect(['A Minor', 'C Major'], contains(name));
    }
  });

  test('resolves tracks behind a release link', () async {
    if (!available) return markTestSkipped('no credentials');
    // Find a real release id from a track, since a hardcoded one may vanish.
    final page = await catalog.tracks(TrackQuery(perPage: 1));
    final payload = await catalog.client.get(
      '/catalog/tracks/${page.results.single.id}/',
    );
    final releaseId = (payload['release'] as Map<String, dynamic>)['id'] as int;

    final tracks = await catalog
        .linkTracks(
          BeatportLink(type: LinkType.release, id: releaseId),
          limit: 50,
        )
        .toList();
    expect(tracks, isNotEmpty);
    expect(tracks.every((t) => t.id != null), isTrue);
  });

  test('resolves tracks behind a label link', () async {
    if (!available) return markTestSkipped('no credentials');
    final page = await catalog.tracks(TrackQuery(perPage: 1));
    final payload = await catalog.client.get(
      '/catalog/tracks/${page.results.single.id}/',
    );
    final release = payload['release'] as Map<String, dynamic>;
    final labelId = (release['label'] as Map<String, dynamic>)['id'] as int;

    final tracks = await catalog
        .linkTracks(BeatportLink(type: LinkType.label, id: labelId), limit: 30)
        .toList();
    expect(tracks, isNotEmpty);
  });

  test('parallel segment fetch yields the same bytes as sequential', () async {
    if (!available) return markTestSkipped('no credentials');
    final page = await catalog.tracks(TrackQuery(perPage: 1));
    final track = page.results.single;

    // Segments are written in completion order if Future.wait's ordering is
    // ever assumed wrongly, which would corrupt the audio while leaving the
    // file a plausible size. Comparing the two byte for byte catches that.
    final sequentialDir = await temp.createTemp('seq');
    final parallelDir = await temp.createTemp('par');

    final sequential = await Downloader(
      catalog: catalog,
      httpClient: client,
      segmentConcurrency: 1,
    ).downloadTrack(track, sequentialDir, quality: AudioQuality.hls);

    final parallel = await Downloader(
      catalog: catalog,
      httpClient: client,
      segmentConcurrency: 8,
    ).downloadTrack(track, parallelDir, quality: AudioQuality.hls);

    final a = await File(sequential.path).readAsBytes();
    final b = await File(parallel.path).readAsBytes();
    expect(b.length, a.length, reason: 'same stream, same byte count');
    expect(b, orderedEquals(a));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('previews the whole track, not a clip', () async {
    if (!available) return markTestSkipped('no credentials');
    final page = await catalog.tracks(TrackQuery(perPage: 1));
    final track = page.results.single;

    final downloader = Downloader(catalog: catalog, httpClient: client);
    final whole = await temp.createTemp('whole');
    final clip = await temp.createTemp('clip');

    var total = 0;
    final full = await downloader.downloadPreview(
      track.id!,
      whole,
      onProgress: (p) => total = p.total,
    );
    final short = await downloader.downloadPreview(track.id!, clip, segments: 3);

    // Default must cover the whole playlist, not a fixed handful of segments.
    expect(total, greaterThan(10), reason: 'a full track is dozens of segments');
    expect(
      await full.length(),
      greaterThan(await short.length() * 3),
      reason: 'the full preview is much longer than a three segment clip',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('builds a preview file the player can decode', () async {
    if (!available) return markTestSkipped('no credentials');
    final page = await catalog.tracks(TrackQuery(perPage: 1));
    final track = page.results.single;

    final downloader = Downloader(catalog: catalog, httpClient: client);
    final file = await downloader.downloadPreview(track.id!, temp, segments: 3);

    expect(await file.exists(), isTrue);
    expect(file.path, endsWith('.aac'));
    expect(await file.length(), greaterThan(20000));

    // The audio-only libmpv build cannot demux encrypted HLS, which is why the
    // preview is decrypted here first. Confirm the result really is plain ADTS
    // behind its ID3 tag, since that is what the player is handed.
    final head = await file.openRead(0, 64).first;
    expect(String.fromCharCodes(head.sublist(0, 3)), 'ID3');
    final tagSize = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
    final frame = await file.openRead(10 + tagSize, 12 + tagSize).first;
    expect(frame[0], 0xFF);
    expect(frame[1] & 0xF0, 0xF0);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('downloads a track as FLAC', () async {
    if (!available) return markTestSkipped('no credentials');
    final page = await catalog.tracks(TrackQuery(perPage: 1));
    final track = page.results.single;

    final downloader = Downloader(catalog: catalog, httpClient: client);
    final result = await downloader.downloadTrack(
      track,
      temp,
      quality: AudioQuality.lossless,
    );

    final file = File(result.path);
    expect(await file.exists(), isTrue);
    expect(result.path, endsWith('.flac'));

    final bytes = await file.length();
    expect(bytes, greaterThan(1000000), reason: 'a FLAC track is megabytes');

    // Verify it is really FLAC, not an error page saved under the name.
    final header = await file.openRead(0, 4).first;
    expect(String.fromCharCodes(header), 'fLaC');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('downloads a track over HLS and decrypts it', () async {
    if (!available) return markTestSkipped('no credentials');
    final page = await catalog.tracks(TrackQuery(perPage: 1));
    final track = page.results.single;

    final downloader = Downloader(catalog: catalog, httpClient: client);
    var segments = 0;
    final result = await downloader.downloadTrack(
      track,
      temp,
      quality: AudioQuality.hls,
      onProgress: (p) => segments = p.total,
    );

    final file = File(result.path);
    expect(await file.exists(), isTrue);
    expect(segments, greaterThan(1), reason: 'the playlist has many segments');

    final bytes = await file.length();
    expect(bytes, greaterThan(100000));

    // Decryption is the part that fails silently: wrong key material yields a
    // file of plausible size that is not audio. Segments open with an ID3v2
    // tag, and the AAC itself begins right after it, so checking both proves
    // the plaintext is really audio rather than noise that happens to be long
    // enough.
    final head = await file.openRead(0, 64).first;
    expect(String.fromCharCodes(head.sublist(0, 3)), 'ID3');

    // ID3v2 size is synchsafe: seven bits per byte.
    final tagSize = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
    final audioStart = 10 + tagSize;
    final frame = await file.openRead(audioStart, audioStart + 2).first;
    expect(frame[0], 0xFF, reason: 'ADTS sync word after the ID3 tag');
    expect(frame[1] & 0xF0, 0xF0);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
