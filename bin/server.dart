library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/errors.dart';
import 'package:beatport_digger/engine/hls.dart';
import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/engine/token.dart';

class InMemoryTokenStore implements TokenStore {
  TokenPair? _token;

  @override
  Future<TokenPair?> read() async => _token;

  @override
  Future<void> write(TokenPair token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}

final http.Client _http = http.Client();
Catalog? _catalog;

final Directory _previewCache = Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}beatport_digger_previews',
);

const int _segmentWindow = 32;

const Map<String, String> _cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

const Map<String, String> _json = {'content-type': 'application/json'};

Response _ok(Object data) =>
    Response.ok(jsonEncode(data), headers: {..._json, ..._cors});

Response _error(int status, String message) => Response(
  status,
  body: jsonEncode({'error': message}),
  headers: {..._json, ..._cors},
);

String? _blankToNull(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, dynamic> _trackJson(Track track) {
  final number = track.key?.camelotNumber;
  final letter = track.key?.camelotLetter;
  return {
    'id': track.id,
    'title': track.title,
    'artists': track.artistNames,
    'label': track.labelName,
    'genre': track.subGenreName.isEmpty ? track.genreName : track.subGenreName,
    'bpm': track.bpm,
    'key': (number != null && letter != null) ? '$number$letter' : null,
    'length': track.length,
    'badges': track.badges,
  };
}

Future<Response> _login(Request request) async {
  Map<String, dynamic> body;
  try {
    body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
  } on Object {
    return _error(400, 'Expected a JSON body.');
  }
  final username = _blankToNull(body['username'] as String?);
  final password = _blankToNull(body['password'] as String?);
  if (username == null || password == null) {
    return _error(400, 'A username and password are required.');
  }

  try {
    final auth = Authenticator(httpClient: _http, store: InMemoryTokenStore());
    await auth.logIn(username, password);
    _catalog = Catalog(BeatportClient(auth: auth, httpClient: _http));
    return _ok({'ok': true});
  } on AuthException catch (exception) {
    return _error(401, exception.message);
  } on BeatportException catch (exception) {
    return _error(exception.status, exception.toString());
  } on Object catch (exception) {
    return _error(500, 'Sign-in failed: $exception');
  }
}

Response _status(Request request) => _ok({'authenticated': _catalog != null});

final Map<String, ({DateTime at, String body})> _searchCache = {};
const Duration _searchTtl = Duration(seconds: 120);

Future<Response> _search(Request request) async {
  final catalog = _catalog;
  if (catalog == null) return _error(401, 'Sign in first.');

  final q = request.url.queryParameters;
  final bpmLow = q['bpmLow']?.trim() ?? '';
  final bpmHigh = q['bpmHigh']?.trim() ?? '';
  final bpm = (bpmLow.isEmpty && bpmHigh.isEmpty) ? null : '$bpmLow:$bpmHigh';
  final genre = int.tryParse(q['genre'] ?? '');
  final sort = _blankToNull(q['sort']) ?? '-publish_date';
  final page = int.tryParse(q['page'] ?? '1') ?? 1;

  final perPage = (int.tryParse(q['perPage'] ?? '') ?? 60).clamp(10, 150);

  final cacheKey = request.url.query;
  final cached = _searchCache[cacheKey];
  if (cached != null && DateTime.now().difference(cached.at) < _searchTtl) {
    return Response.ok(cached.body, headers: {..._json, ..._cors});
  }

  final query = TrackQuery(
    name: _blankToNull(q['title']),
    artistName: _blankToNull(q['artist']),
    labelName: _blankToNull(q['label']),
    genreId: genre == null ? null : [genre],
    bpm: bpm,
    orderBy: sort,
    perPage: perPage,
  );

  try {
    final result = await catalog.tracks(query, page: page);
    final body = jsonEncode({
      'count': result.count,
      'hasNext': result.next != null,
      'page': page,
      'results': result.results.map(_trackJson).toList(),
    });
    _searchCache[cacheKey] = (at: DateTime.now(), body: body);
    return Response.ok(body, headers: {..._json, ..._cors});
  } on BeatportException catch (exception) {
    return _error(exception.status, exception.toString());
  } on Object catch (exception) {
    return _error(500, 'Search failed: $exception');
  }
}

List<String> _harmonicNeighbours(String code) {
  final match = RegExp(r'^(\d{1,2})([AB])$').firstMatch(code.toUpperCase());
  if (match == null) return const [];
  final number = int.parse(match.group(1)!);
  if (number < 1 || number > 12) return const [];
  final letter = match.group(2)!;
  final up = number % 12 + 1;
  final down = (number - 2) % 12 + 1;
  final opposite = letter == 'A' ? 'B' : 'A';
  return ['$number$letter', '$up$letter', '$down$letter', '$number$opposite'];
}

Future<Response> _harmonic(Request request) async {
  final catalog = _catalog;
  if (catalog == null) return _error(401, 'Sign in first.');

  final q = request.url.queryParameters;
  final code = _blankToNull(q['key']) ?? '8A';
  final bpmLow = q['bpmLow']?.trim() ?? '';
  final bpmHigh = q['bpmHigh']?.trim() ?? '';
  final bpm = (bpmLow.isEmpty && bpmHigh.isEmpty) ? null : '$bpmLow:$bpmHigh';
  final genre = int.tryParse(q['genre'] ?? '');

  try {
    final grouped = await catalog.keyIdsByCamelot();
    final ids = <int>[
      for (final neighbour in _harmonicNeighbours(code)) ...?grouped[neighbour],
    ];
    if (ids.isEmpty) return _ok({'count': 0, 'hasNext': false, 'results': []});

    final query = TrackQuery(
      keyId: ids,
      genreId: genre == null ? null : [genre],
      bpm: bpm,
      orderBy: '-publish_date',
      perPage: 100,
    );
    final result = await catalog.tracks(query, page: 1);
    return _ok({
      'count': result.count,
      'hasNext': result.next != null,
      'results': result.results.map(_trackJson).toList(),
    });
  } on BeatportException catch (exception) {
    return _error(exception.status, exception.toString());
  } on Object catch (exception) {
    return _error(500, 'Harmonic search failed: $exception');
  }
}

Future<Response> _genres(Request request) async {
  final catalog = _catalog;
  if (catalog == null) return _error(401, 'Sign in first.');
  try {
    final genres = await catalog.genres();
    return _ok({
      'genres': [
        for (final g in genres)
          if (g.id != null) {'id': g.id, 'name': g.name ?? ''},
      ],
    });
  } on Object catch (exception) {
    return _error(500, 'Could not load genres: $exception');
  }
}

const Map<String, String> _audioHeaders = {
  'content-type': 'audio/aac',

  'cache-control': 'public, max-age=86400',
  ..._cors,
};

Future<Response> _preview(Request request, String rawId) async {
  final catalog = _catalog;
  if (catalog == null) return _error(401, 'Sign in first.');
  final id = int.tryParse(rawId);
  if (id == null) return _error(400, 'Bad track id.');

  final cacheFile = File(
    '${_previewCache.path}${Platform.pathSeparator}$id.aac',
  );
  if (await cacheFile.exists()) {
    return Response.ok(await cacheFile.readAsBytes(), headers: _audioHeaders);
  }

  try {
    final stream = await catalog.trackStream(id);
    if (stream.url.isEmpty) return _error(404, 'No preview for this track.');

    final (playlist, key) = await loadStream(
      Uri.parse(stream.url),
      httpClient: _http,
    );

    final segments = playlist.segments;
    final parts = List<Uint8List?>.filled(segments.length, null);
    for (var start = 0; start < segments.length; start += _segmentWindow) {
      final end = math.min(start + _segmentWindow, segments.length);
      await Future.wait([
        for (var i = start; i < end; i++)
          _fetchSegment(segments[i], key).then((bytes) => parts[i] = bytes),
      ]);
    }

    final builder = BytesBuilder(copy: false);
    for (final part in parts) {
      if (part != null) builder.add(part);
    }
    final bytes = builder.takeBytes();

    unawaited(
      _previewCache
          .create(recursive: true)
          .then((_) => cacheFile.writeAsBytes(bytes))
          .catchError((_) => cacheFile),
    );

    return Response.ok(bytes, headers: _audioHeaders);
  } on BeatportException catch (exception) {
    return _error(exception.status, 'Preview unavailable.');
  } on Object catch (exception) {
    return _error(500, 'Preview failed: $exception');
  }
}

Future<Uint8List> _fetchSegment(Uri url, StreamKey? key) async {
  final response = await _http.get(url);
  if (response.statusCode != 200) {
    throw BeatportException(response.statusCode, 'segment failed');
  }
  final payload = Uint8List.fromList(response.bodyBytes);
  return key == null ? payload : decryptSegment(payload, key);
}

Handler _staticOrHint() {
  final dist = Directory('web/frontend/dist');
  if (dist.existsSync()) {
    return (Request request) async {
      final path = request.url.path.isEmpty ? 'index.html' : request.url.path;
      var file = File('${dist.path}/$path');
      if (!file.existsSync()) file = File('${dist.path}/index.html');
      final bytes = await file.readAsBytes();
      final type = path.endsWith('.js')
          ? 'text/javascript'
          : path.endsWith('.css')
          ? 'text/css'
          : path.endsWith('.html') || !path.contains('.')
          ? 'text/html'
          : 'application/octet-stream';
      return Response.ok(bytes, headers: {'content-type': type});
    };
  }
  return (Request request) => Response.ok(
    'BeatPort Digger backend is running. Start the React app '
    '(web/frontend: npm run dev) or build it into web/frontend/dist.',
    headers: {'content-type': 'text/plain'},
  );
}

Middleware _corsMiddleware() =>
    (Handler inner) => (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _cors);
      }
      return inner(request);
    };

Future<void> main(List<String> args) async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  final api = Router()
    ..post('/api/login', _login)
    ..get('/api/status', _status)
    ..get('/api/search', _search)
    ..get('/api/harmonic', _harmonic)
    ..get('/api/genres', _genres)
    ..get('/api/preview/<id>', _preview);

  final handler = Cascade().add(api.call).add(_staticOrHint()).handler;

  final pipeline = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addHandler(handler);

  final server = await shelf_io.serve(pipeline, InternetAddress.anyIPv4, port);
  server.autoCompress = true;

  stdout.writeln('BeatPort Digger backend listening on port ${server.port}');
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final addr in interface.addresses) {
      stdout.writeln('  http://${addr.address}:${server.port}');
    }
  }
}
