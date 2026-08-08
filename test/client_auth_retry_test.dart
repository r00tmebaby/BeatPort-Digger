import 'dart:convert';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryTokenStore implements TokenStore {
  TokenPair? stored;

  @override
  Future<TokenPair?> read() async => stored;

  @override
  Future<void> write(TokenPair token) async => stored = token;

  @override
  Future<void> clear() async => stored = null;
}

void main() {
  test(
    'stale in-flight 401 retries with newer token without extra refresh',
    () async {
      var tokenRequests = 0;
      var staleRequests = 0;

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/o/token/')) {
          tokenRequests += 1;
          if (tokenRequests > 1) {
            return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
          }
          return http.Response(
            jsonEncode({
              'access_token': 'fresh-access',
              'refresh_token': 'fresh-refresh',
              'expires_in': 36000,
              'token_type': 'Bearer',
            }),
            200,
          );
        }

        if (request.url.path.endsWith('/catalog/test/')) {
          final authz = request.headers['Authorization'] ?? '';
          if (authz == 'Bearer stale-access') {
            staleRequests += 1;
            if (staleRequests == 2) {
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
            return http.Response('', 401);
          }
          if (authz == 'Bearer fresh-access') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('', 401);
        }

        return http.Response('not found', 404);
      });

      final auth = Authenticator(
        httpClient: client,
        store: _MemoryTokenStore(),
      );
      auth.token = TokenPair(
        accessToken: 'stale-access',
        refreshToken: 'stale-refresh',
        expiresIn: 36000,
        issuedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );

      final api = BeatportClient(auth: auth, httpClient: client);
      final results = await Future.wait([
        api.get('/catalog/test/'),
        api.get('/catalog/test/'),
      ]);

      expect(results, everyElement(containsPair('ok', true)));
      expect(
        tokenRequests,
        1,
        reason:
            'stale in-flight requests should not spend another refresh token',
      );
      expect(auth.token?.accessToken, 'fresh-access');
    },
  );
}
