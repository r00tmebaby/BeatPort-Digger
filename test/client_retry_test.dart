import 'dart:convert';
import 'dart:math' as math;

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/errors.dart';
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

/// A [math.Random] that always returns zero, so retry delays are exact.
class _NoJitter implements math.Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}

Authenticator _authWith(http.Client client, {String access = 'live-access'}) {
  final auth = Authenticator(httpClient: client, store: _MemoryTokenStore());
  auth.token = TokenPair(
    accessToken: access,
    refreshToken: 'live-refresh',
    expiresIn: 36000,
    issuedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  return auth;
}

void main() {
  group('entitlement refusals', () {
    test('a 403 about the account does not spend a refresh token', () async {
      var tokenRequests = 0;
      var catalogRequests = 0;

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/o/token/')) {
          tokenRequests += 1;
          return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
        }
        catalogRequests += 1;
        return http.Response(
          jsonEncode({
            'detail': 'You do not have permission to perform this action.',
          }),
          403,
        );
      });

      final auth = _authWith(client);
      final api = BeatportClient(auth: auth, httpClient: client);

      await expectLater(
        api.get('/catalog/tracks/1/download/'),
        throwsA(
          isA<BeatportException>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e, 'is not an auth failure', isNot(isA<AuthException>())),
        ),
      );

      expect(
        tokenRequests,
        0,
        reason:
            'a track the account cannot have says nothing about the token; '
            'refreshing here is what burns the single-use refresh chain '
            'during a bulk download',
      );
      expect(catalogRequests, 1, reason: 'an entitlement refusal is final');
      expect(auth.token, isNotNull);
      expect(auth.sessionExpired, isFalse);
    });

    test('a 403 that names the token still refreshes', () async {
      var tokenRequests = 0;

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/o/token/')) {
          tokenRequests += 1;
          return http.Response(
            jsonEncode({
              'access_token': 'fresh-access',
              'refresh_token': 'fresh-refresh',
              'expires_in': 36000,
            }),
            200,
          );
        }
        if (request.headers['Authorization'] == 'Bearer fresh-access') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response(
          jsonEncode({'detail': 'Given token not valid for any token type'}),
          403,
        );
      });

      final auth = _authWith(client);
      final api = BeatportClient(auth: auth, httpClient: client);

      expect(await api.get('/catalog/tracks/'), containsPair('ok', true));
      expect(tokenRequests, 1);
    });

    test('classification keeps entitlement and credentials apart', () {
      String body(String detail) => jsonEncode({'detail': detail});

      expect(isCredentialFailure(401, ''), isTrue);
      expect(isCredentialFailure(404, body('nope')), isFalse);
      expect(isCredentialFailure(403, body('no active subscription')), isFalse);
      expect(
        isCredentialFailure(403, body('You do not have permission.')),
        isFalse,
      );
      expect(
        isCredentialFailure(403, body('Authentication credentials missing')),
        isTrue,
      );
      expect(isCredentialFailure(403, '', 'Bearer realm="api"'), isTrue);

      // A subscription that lapsed reads a lot like a token that lapsed.
      expect(
        isCredentialFailure(403, body('Your subscription has expired')),
        isFalse,
      );
    });
  });

  group('transient failures', () {
    test('a rate limit is retried and then succeeds', () async {
      var attempts = 0;
      final slept = <Duration>[];

      final client = MockClient((request) async {
        attempts += 1;
        if (attempts < 3) {
          return http.Response(jsonEncode({'detail': 'slow down'}), 429);
        }
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      final api = BeatportClient(
        auth: _authWith(client),
        httpClient: client,
        sleep: (delay) async => slept.add(delay),
        jitter: _NoJitter(),
      );

      expect(await api.get('/catalog/tracks/'), containsPair('ok', true));
      expect(attempts, 3);
      expect(
        slept,
        [const Duration(milliseconds: 250), const Duration(milliseconds: 500)],
        reason: 'the wait should grow between attempts',
      );
    });

    test('Retry-After wins over the computed backoff', () async {
      var attempts = 0;
      final slept = <Duration>[];

      final client = MockClient((request) async {
        attempts += 1;
        if (attempts == 1) {
          return http.Response('', 429, headers: {'retry-after': '7'});
        }
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      final api = BeatportClient(
        auth: _authWith(client),
        httpClient: client,
        sleep: (delay) async => slept.add(delay),
        jitter: _NoJitter(),
      );

      await api.get('/catalog/tracks/');
      expect(slept, [const Duration(seconds: 7)]);
    });

    test('an absurd Retry-After is capped', () {
      final api = BeatportClient(
        auth: _authWith(MockClient((_) async => http.Response('', 200))),
        jitter: _NoJitter(),
      );
      expect(api.retryDelay(1, '999999'), maxHonouredRetryAfter);
    });

    test('a persistent rate limit gives up after the attempt budget', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts += 1;
        return http.Response(jsonEncode({'detail': 'slow down'}), 429);
      });

      final api = BeatportClient(
        auth: _authWith(client),
        httpClient: client,
        sleep: (_) async {},
        jitter: _NoJitter(),
      );

      await expectLater(
        api.get('/catalog/tracks/'),
        throwsA(isA<BeatportException>().having((e) => e.status, 'status', 429)),
      );
      expect(attempts, maxRequestAttempts);
    });

    test('a dropped connection is retried', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts += 1;
        if (attempts == 1) throw http.ClientException('connection reset');
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      final api = BeatportClient(
        auth: _authWith(client),
        httpClient: client,
        sleep: (_) async {},
        jitter: _NoJitter(),
      );

      expect(await api.get('/catalog/tracks/'), containsPair('ok', true));
      expect(attempts, 2);
    });

    test('a 404 is not retried', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts += 1;
        return http.Response(jsonEncode({'detail': 'gone'}), 404);
      });

      final api = BeatportClient(
        auth: _authWith(client),
        httpClient: client,
        sleep: (_) async {},
        jitter: _NoJitter(),
      );

      await expectLater(api.get('/x/'), throwsA(isA<BeatportException>()));
      expect(attempts, 1);
    });
  });

  group('a dead session', () {
    test('a rejected refresh token ends the session once, not forever', () async {
      var expiries = 0;

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/o/token/')) {
          return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
        }
        return http.Response('', 401);
      });

      final auth = _authWith(client)..onSessionExpired = () => expiries += 1;
      final api = BeatportClient(auth: auth, httpClient: client);

      await expectLater(api.get('/catalog/tracks/'), throwsA(isA<AuthException>()));

      expect(auth.sessionExpired, isTrue);
      expect(
        auth.token,
        isNull,
        reason: 'holding a dead token made every later request fail while the '
            'app still looked signed in',
      );
      expect(expiries, 1);
    });

    test('a 5xx from the token endpoint keeps the session', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/o/token/')) {
          return http.Response('', 503);
        }
        return http.Response('', 401);
      });

      final auth = _authWith(client);
      final api = BeatportClient(auth: auth, httpClient: client);

      await expectLater(api.get('/catalog/tracks/'), throwsA(isA<AuthException>()));
      expect(
        auth.token,
        isNotNull,
        reason: 'a gateway hiccup is not proof the credentials are dead',
      );
      expect(auth.sessionExpired, isFalse);
    });

    test('a concurrent burst of 401s shares one refresh', () async {
      var tokenRequests = 0;

      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/o/token/')) {
          tokenRequests += 1;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response(
            jsonEncode({
              'access_token': 'fresh-access',
              'refresh_token': 'fresh-refresh',
              'expires_in': 36000,
            }),
            200,
          );
        }
        if (request.headers['Authorization'] == 'Bearer fresh-access') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        // Stagger the refusals so some land after the refresh has finished,
        // which is the case the in-flight guard alone does not cover.
        await Future<void>.delayed(const Duration(milliseconds: 35));
        return http.Response('', 401);
      });

      final auth = _authWith(client, access: 'stale-access');
      final api = BeatportClient(auth: auth, httpClient: client);

      final results = await Future.wait([
        for (var i = 0; i < 16; i++) api.get('/catalog/tracks/'),
      ]);

      expect(results, everyElement(containsPair('ok', true)));
      expect(
        tokenRequests,
        1,
        reason: 'sixteen downloads hitting 401 together must not spend '
            'sixteen single-use refresh tokens',
      );
    });
  });
}
