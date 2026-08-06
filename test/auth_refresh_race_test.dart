library;

import 'dart:convert';

import 'package:beatport_digger/engine/auth.dart';
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
    'refresh() shares one in-flight request across concurrent callers',
    () async {
      var tokenRequests = 0;

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/o/token/')) {
          tokenRequests += 1;
          // A slow refresh makes the race window wide enough that, without
          // the single-flight guard, every concurrent caller would have
          // already read the (soon to be stale) refresh token and issued
          // its own request before the first response comes back.
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response(
            jsonEncode({
              'access_token': 'new-access-$tokenRequests',
              'refresh_token': 'new-refresh-$tokenRequests',
              'expires_in': 36000,
              'token_type': 'Bearer',
              'scope': 'app:locker user:dj',
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final store = _MemoryTokenStore();
      final auth = Authenticator(httpClient: client, store: store);
      auth.token = const TokenPair(
        accessToken: 'stale-access',
        refreshToken: 'stale-refresh',
        expiresIn: 36000,
        issuedAt: 0,
      );

      // Sixteen "downloads" all hit a 401 at once and each ask the
      // authenticator to refresh, exactly as client.dart's get() does.
      final results = await Future.wait([
        for (var i = 0; i < 16; i++) auth.refresh(),
      ]);

      expect(results, everyElement(isTrue));
      expect(
        tokenRequests,
        1,
        reason:
            'every concurrent 401 should share a single refresh instead of '
            'each spending the single-use refresh token',
      );
      expect(auth.token?.accessToken, 'new-access-1');
    },
  );
}
