/// Live checks against the Beatport API.
///
/// Tagged live and skipped by default so the normal test run stays offline.
/// Needs credentials in BEATPORT_USERNAME and BEATPORT_PASSWORD. Run with:
///   flutter test test/live_api_test.dart --run-skipped
@Tags(['live'])
library;

import 'dart:io';

import 'package:beatport_digger/engine/auth.dart';
import 'package:beatport_digger/engine/catalog.dart';
import 'package:beatport_digger/engine/client.dart';
import 'package:beatport_digger/engine/token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final username = Platform.environment['BEATPORT_USERNAME'];
  final password = Platform.environment['BEATPORT_PASSWORD'];
  final haveCredentials =
      username != null &&
      username.isNotEmpty &&
      password != null &&
      password.isNotEmpty;

  late Directory tempDir;
  late Authenticator auth;
  late Catalog catalog;
  late http.Client httpClient;

  setUpAll(() async {
    if (!haveCredentials) return;
    tempDir = await Directory.systemTemp.createTemp('bpcat_live');
    httpClient = http.Client();
    auth = Authenticator(
      httpClient: httpClient,
      store: FileTokenStore('${tempDir.path}/token.json'),
    );
    catalog = Catalog(BeatportClient(auth: auth, httpClient: httpClient));
  });

  tearDownAll(() async {
    if (!haveCredentials) return;
    httpClient.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('logs in and issues a token pair', () async {
    final token = await auth.logIn(username!, password!);
    expect(token.accessToken, isNotEmpty);
    expect(token.refreshToken, isNotNull);
    expect(token.expiresIn, greaterThan(0));
    expect(token.loginId, computeLoginId(username, password));
    expect(token.isExpired(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'caches the token and reloads it without credentials',
    () async {
      final reloaded = await auth.loadCached();
      expect(reloaded, isNotNull);
      expect(reloaded!.accessToken, auth.token!.accessToken);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('rejects a cache belonging to another account', () async {
    final other = await auth.loadCached(
      username: 'someone_else',
      password: 'different',
    );
    expect(other, isNull);
  });

  test(
    'refreshes the token, rotating it and keeping the login id',
    () async {
      final before = auth.token!;
      expect(await auth.refresh(), isTrue);
      final after = auth.token!;
      expect(after.accessToken, isNot(before.accessToken));
      expect(after.loginId, before.loginId);
      expect(after.isExpired(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('fetches genres', () async {
    final genres = await catalog.genres();
    expect(genres.length, greaterThan(30));
    expect(genres.any((g) => g.name == 'Amapiano'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'publish_date is ignored by the API, new_release_date is not',
    () async {
      // The API silently disregards a publish_date range: it is accepted and then
      // ignored, returning the unfiltered catalog.
      final filtered = TrackQuery(
        genreId: [89],
        orderBy: 'publish_date',
        perPage: 20,
      ).dated(DateTime(2019, 5, 1), DateTime(2019, 5, 7));

      final page = await catalog.tracks(filtered);
      expect(page.count, lessThan(2000));
      for (final track in page.results) {
        expect(track.newReleaseDate, isNotNull);
        expect(
          track.newReleaseDate!.compareTo('2019-05-01') >= 0 &&
              track.newReleaseDate!.compareTo('2019-05-07') <= 0,
          isTrue,
          reason: 'row outside the requested window: ${track.newReleaseDate}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'rejects an offset past the result window',
    () async {
      final query = TrackQuery(
        genreId: [89],
        orderBy: 'publish_date',
        perPage: 100,
      );
      await expectLater(
        catalog.tracks(query, page: 101),
        throwsA(isA<Exception>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'exports a full year as a stable, deduplicated track count',
    () async {
      // Amapiano 2023 resolves to 4,427 distinct tracks across two split
      // strategies; the count must stay stable.
      final query = TrackQuery(
        genreId: [98],
        orderBy: 'publish_date',
        perPage: 2000,
      );
      final windows = <ExportWindow>[];
      final ids = <int>{};

      await for (final track in catalog.exportTracks(
        query,
        DateTime(2023, 1, 1),
        DateTime(2023, 12, 31),
        onWindow: windows.add,
      )) {
        if (track.id != null) ids.add(track.id!);
      }

      expect(ids.length, 4427);
      expect(windows, isNotEmpty);
      expect(windows.every((w) => !w.truncated), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test(
    'a different split strategy yields the same set',
    () async {
      final query = TrackQuery(
        genreId: [98],
        orderBy: 'publish_date',
        perPage: 200,
      );
      final ids = <int>{};
      await for (final track in catalog.exportTracks(
        query,
        DateTime(2023, 1, 1),
        DateTime(2023, 12, 31),
      )) {
        if (track.id != null) ids.add(track.id!);
      }
      expect(ids.length, 4427);
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
