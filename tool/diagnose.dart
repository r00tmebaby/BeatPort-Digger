library;

import 'dart:io';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/errors.dart';
import 'package:beatport_digger/engine/hls.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:http/http.dart' as http;

final List<String> _findings = [];

void heading(String text) => stdout.writeln('\n== $text ==');
void line(String text) => stdout.writeln('   $text');
void finding(String text) {
  _findings.add(text);
  stdout.writeln('   -> $text');
}

String safeUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return '<unparseable>';
  final query = uri.query.isEmpty
      ? ''
      : ' (+${uri.queryParameters.length} query params)';
  return '${uri.origin}${uri.path}$query';
}

String promptFor(String label, {bool hidden = false}) {
  stdout.write('$label: ');
  if (!hidden) return stdin.readLineSync() ?? '';
  final wasEchoing = stdin.echoMode;
  stdin.echoMode = false;
  final value = stdin.readLineSync() ?? '';
  stdin.echoMode = wasEchoing;
  stdout.writeln();
  return value;
}

Future<void> probeUrl(http.Client client, String label, Uri url) async {
  line('$label: ${safeUrl(url.toString())}');

  for (final entry in {
    'as the app sends it': defaultHeaders,
    'with no headers': <String, String>{},
  }.entries) {
    final isAppPath = entry.value.isNotEmpty;
    try {
      final response = await client.get(
        url,
        headers: {...entry.value, 'range': 'bytes=0-1023'},
      );
      final ok = response.statusCode == 200 || response.statusCode == 206;
      line(
        '  ${entry.key.padRight(20)} ${response.statusCode} '
        '${response.bodyBytes.length} bytes'
        '${ok ? '' : ' - ${response.body.trim().split('\n').first}'}',
      );
      if (!ok && isAppPath) {
        finding('$label refused the app: HTTP ${response.statusCode}');
      }
    } on Object catch (exception) {
      if (isAppPath) finding('$label failed for the app: $exception');
    }
  }
}

Future<void> main(List<String> arguments) async {
  final username =
      Platform.environment['BEATPORT_USERNAME'] ??
      promptFor('Beatport username');
  final password =
      Platform.environment['BEATPORT_PASSWORD'] ??
      promptFor('Beatport password', hidden: true);
  if (username.isEmpty || password.isEmpty) {
    stderr.writeln('No credentials given.');
    exit(2);
  }

  final client = http.Client();
  final temp = await Directory.systemTemp.createTemp('bpdiag');
  final auth = Authenticator(
    httpClient: client,
    store: FileTokenStore('${temp.path}/token.json'),
  );
  final catalog = Catalog(BeatportClient(auth: auth, httpClient: client));

  try {
    heading('1. Login');
    TokenPair token;
    try {
      token = await auth.logIn(username, password);
      line('access token issued, ${token.accessToken.length} chars');
      line('token type: ${token.tokenType}');
      line('scope: ${token.scope.isEmpty ? '<none returned>' : token.scope}');
      line('expires in: ${token.expiresIn}s (${token.expiresOn})');
      line(
        'refresh token: ${token.refreshToken == null ? 'absent' : 'present'}',
      );
      if (!token.scope.contains('user:dj')) {
        finding(
          'token scope does not include user:dj; streaming and downloads are '
          'granted through it',
        );
      }
    } on Object catch (exception) {
      finding('login failed: $exception');
      rethrow;
    }

    heading('2. Catalog read (proves the token works for browsing)');
    final genres = await catalog.genres(perPage: 5);
    line('genres returned: ${genres.length}');

    heading('3. Account entitlement');
    try {
      final me = await catalog.client.get('/auth/o/introspect/');
      final subscription = me['subscription'];
      final feature = me['feature'];
      line(
        'person: ${me['person'] is Map ? (me['person'] as Map)['id'] : '?'}',
      );
      line('subscription: ${subscription ?? '<none>'}');
      line(
        'features: ${feature is List ? feature.join(', ') : feature ?? '<none>'}',
      );
      if (subscription == null) {
        finding(
          'the account reports no active subscription; Beatport serves stream '
          'and download only to subscribed accounts',
        );
      }
    } on Object catch (exception) {
      line('introspect unavailable: $exception');
    }

    heading('4. Pick a track');
    final pinned = Platform.environment['BEATPORT_TRACK_ID'];
    int trackId;
    if (pinned != null && pinned.isNotEmpty) {
      trackId = int.parse(pinned);
      line('using pinned track $trackId');
    } else {
      final page = await catalog.tracks(TrackQuery(perPage: 1));
      final first = page.results.isEmpty ? null : page.results.first;
      if (first?.id == null) {
        finding('the catalog returned no tracks to test with');
        return;
      }
      trackId = first!.id!;
      line('using $trackId - ${first.name ?? '?'}');
    }

    heading('5. Stream endpoint (drives the preview)');
    String? streamUrl;
    try {
      final stream = await catalog.trackStream(trackId);
      streamUrl = stream.url;
      line(
        'stream_url: ${stream.url.isEmpty ? '<empty>' : safeUrl(stream.url)}',
      );
      line(
        'sample window: ${stream.sampleStartMs} .. ${stream.sampleEndMs} ms',
      );
      if (stream.url.isEmpty) {
        finding('the stream endpoint answered 200 but carried no stream_url');
      }
    } on BeatportException catch (exception) {
      finding('stream endpoint refused the track: $exception');
    }

    heading('6. Download endpoint (drives the downloader)');
    final locations = <String, String>{};
    for (final quality in ['lossless', 'high', 'medium']) {
      try {
        final download = await catalog.trackDownload(trackId, quality);
        line(
          '$quality: ${download.streamQuality} '
          '${download.location.isEmpty ? '<no location>' : safeUrl(download.location)}',
        );
        if (download.location.isNotEmpty)
          locations[quality] = download.location;
      } on BeatportException catch (exception) {
        line('$quality: $exception');
        finding('download endpoint refused $quality: $exception');
      }
    }

    heading('7. Pre-signed download URL fetch (no bearer token is sent)');
    if (locations.isEmpty) {
      line('skipped: the download endpoint returned no location');
    } else {
      final entry = locations.entries.first;
      await probeUrl(client, 'download (${entry.key})', Uri.parse(entry.value));
    }

    heading('8. HLS playlist, key and first segment');
    if (streamUrl == null || streamUrl.isEmpty) {
      line('skipped: no stream URL');
    } else {
      final playlistUri = Uri.parse(streamUrl);
      await probeUrl(client, 'playlist', playlistUri);
      try {
        final (playlist, key) = await loadStream(
          playlistUri,
          httpClient: client,
        );
        line('segments: ${playlist.segments.length}');
        line('encrypted: ${playlist.isEncrypted}');
        if (key != null) line('key length: ${key.value.length} bytes');
        if (playlist.segments.isNotEmpty) {
          await probeUrl(client, 'segment 1', playlist.segments.first);
        }
      } on Object catch (exception) {
        finding('could not load the playlist or its key: $exception');
      }
    }

    heading('Verdict');
    if (_findings.isEmpty) {
      stdout.writeln('   Every stage succeeded for track $trackId.');
      stdout.writeln('   The break is not in the API path; check the app log.');
    } else {
      for (final item in _findings) {
        stdout.writeln('   - $item');
      }
    }
  } on Object catch (exception) {
    stdout.writeln('\nAborted: $exception');
    exitCode = 1;
  } finally {
    client.close();
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}
