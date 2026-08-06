library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'token.dart';

const String baseUrl = 'https://api.beatport.com/v4';
const String tokenEndpoint = '/auth/o/token/';
const String authorizeEndpoint = '/auth/o/authorize/';
const String loginEndpoint = '/auth/login/';

const Set<int> _redirectStatuses = {301, 302, 303, 307, 308};

const Map<String, String> defaultHeaders = {
  'accept':
      'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,'
      'image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
  'accept-language': 'en-US,en;q=0.9',
  'cache-control': 'max-age=0',
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
};

String? sessionIdFrom(Map<String, String> headers) {
  final raw = headers['set-cookie'];
  if (raw == null) return null;
  final match = RegExp(r'sessionid=([^;,\s]+)').firstMatch(raw);
  return match?.group(1);
}

class Authenticator {
  Authenticator({
    required http.Client httpClient,
    required TokenStore store,
    String clientId = publicClientId,
  }) : _http = httpClient,
       _store = store,
       _clientId = clientId;

  final http.Client _http;
  final TokenStore _store;
  final String _clientId;

  TokenPair? token;

  Future<bool>? _refreshing;

  bool get isAuthenticated => token != null;

  Future<TokenPair?> loadCached({String? username, String? password}) async {
    final cached = await _store.read();
    if (cached == null) return null;

    if (username != null && password != null && cached.loginId.isNotEmpty) {
      if (cached.loginId != computeLoginId(username, password)) {
        return null;
      }
    }

    token = cached;
    if (!cached.isExpired()) return cached;

    final renewed = await _tryRefresh(cached);
    if (renewed != null) return renewed;

    token = null;
    return null;
  }

  Future<void> check() async {
    final current = token;
    if (current != null && current.isExpired()) {
      await refresh();
    }
  }

  /// Renews the current token. Returns false when a fresh login is required.
  ///
  /// Concurrent callers (e.g. several downloads hitting 401 at once) share a
  /// single in-flight refresh instead of each spending the refresh token:
  /// Beatport's refresh tokens are single-use, so a second request that
  /// raced ahead with the old token would be rejected and read as a fully
  /// expired session even though the first refresh actually succeeded.
  Future<bool> refresh() async {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;

    final current = token;
    if (current == null) return false;

    final future = _tryRefresh(current).then((renewed) => renewed != null);
    _refreshing = future;
    try {
      return await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<TokenPair> logIn(String username, String password) async {
    final sessionId = await _login(username, password);
    final code = await _authorize(sessionId);
    final issued = await _tokenRequest({
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': _clientId,
    });
    return _persist(
      issued.stamped(loginId: computeLoginId(username, password)),
    );
  }

  Future<void> logOut() async {
    token = null;
    await _store.clear();
  }

  Future<TokenPair?> _tryRefresh(TokenPair current) async {
    final refreshToken = current.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return null;
    try {
      final renewed = await _tokenRequest({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': _clientId,
      });

      return _persist(renewed.stamped(loginId: current.loginId));
    } on BeatportException {
      return null;
    }
  }

  Future<String> _login(String username, String password) async {
    final response = await _http.post(
      Uri.parse('$baseUrl$loginEndpoint'),
      headers: {...defaultHeaders, 'content-type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw AuthException(
        response.statusCode,
        errorMessage(response.body).isEmpty
            ? 'login rejected'
            : errorMessage(response.body),
      );
    }

    final sessionId = sessionIdFrom(response.headers);
    if (sessionId == null) {
      throw AuthException(
        response.statusCode,
        'login returned no sessionid cookie',
      );
    }
    return sessionId;
  }

  Future<String> _authorize(String sessionId) async {
    final uri = Uri.parse('$baseUrl$authorizeEndpoint').replace(
      queryParameters: {'client_id': _clientId, 'response_type': 'code'},
    );

    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll({
        ...defaultHeaders,
        'accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
        'cookie': 'sessionid=$sessionId',
      });

    final response = await http.Response.fromStream(await _http.send(request));

    if (!_redirectStatuses.contains(response.statusCode)) {
      throw AuthException(
        response.statusCode,
        errorMessage(response.body).isEmpty
            ? 'authorize did not redirect'
            : errorMessage(response.body),
      );
    }

    final location = response.headers['location'] ?? '';
    final code = Uri.parse(location).queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw AuthException(
        response.statusCode,
        'authorize redirect carried no code',
      );
    }
    return code;
  }

  Future<TokenPair> _tokenRequest(Map<String, String> data) async {
    final response = await _http.post(
      Uri.parse('$baseUrl$tokenEndpoint'),
      headers: {
        ...defaultHeaders,
        'content-type': 'application/x-www-form-urlencoded',
      },
      body: data,
    );

    if (response.statusCode != 200) {
      throw AuthException(response.statusCode, errorMessage(response.body));
    }

    return TokenPair.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    ).stamped();
  }

  Future<TokenPair> _persist(TokenPair value) async {
    token = value;
    await _store.write(value);
    return value;
  }
}
