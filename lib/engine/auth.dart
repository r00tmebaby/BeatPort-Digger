/// The OAuth token lifecycle.
///
/// Reproduces the exchange the Beatport web player performs: a username and
/// password buy a session cookie, the session cookie buys an authorization
/// code, and the code is exchanged for the token pair that authorises later
/// requests. Only the token pair is persisted, so the password is not stored.
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

/// Beatport rejects unfamiliar clients on the login and authorize endpoints, so
/// present the same identity a browser would.
const Map<String, String> defaultHeaders = {
  'accept': 'application/json',
  'accept-language': 'en-US,en;q=0.9',
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
};

/// Pulls the session cookie out of a Set-Cookie header.
///
/// Dart folds repeated Set-Cookie headers into one comma-joined string, so the
/// cookie cannot be read by splitting on commas: expiry dates contain them too.
String? sessionIdFrom(Map<String, String> headers) {
  final raw = headers['set-cookie'];
  if (raw == null) return null;
  final match = RegExp(r'sessionid=([^;,\s]+)').firstMatch(raw);
  return match?.group(1);
}

/// Owns the token pair: loads it, issues it and keeps it fresh.
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

  bool get isAuthenticated => token != null;

  /// Loads a cached token, refreshing it when it is close to expiry.
  ///
  /// Returns null when there is nothing usable cached, which is the signal to
  /// ask for credentials.
  Future<TokenPair?> loadCached({String? username, String? password}) async {
    final cached = await _store.read();
    if (cached == null) return null;

    // A cache issued under different credentials belongs to another account.
    // Only checked when credentials are known, since a cached token is
    // otherwise the only thing we have.
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

  /// Renews ahead of expiry, before a request can be rejected for it.
  Future<void> check() async {
    final current = token;
    if (current != null && current.isExpired()) {
      await refresh();
    }
  }

  /// Renews the current token. Returns false when a fresh login is required.
  Future<bool> refresh() async {
    final current = token;
    if (current == null) return false;
    return await _tryRefresh(current) != null;
  }

  /// Logs in from scratch and exchanges the result for a token pair.
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

  // -- grants ---------------------------------------------------------

  Future<TokenPair?> _tryRefresh(TokenPair current) async {
    final refreshToken = current.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return null;
    try {
      final renewed = await _tokenRequest({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': _clientId,
      });
      // The refresh response omits login_id; carry the original forward so the
      // cache stays tied to the account that issued it.
      return _persist(renewed.stamped(loginId: current.loginId));
    } on BeatportException {
      // Refresh tokens expire and are revoked on password change.
      return null;
    }
  }

  /// Exchanges credentials for a session cookie, as a browser login does.
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

  /// Trades the session cookie for a single-use authorization code.
  ///
  /// The code arrives in the Location header of a redirect, so the request must
  /// not follow it: following would consume the header and land on a page that
  /// carries no code.
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
