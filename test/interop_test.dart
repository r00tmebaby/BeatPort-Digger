library;

import 'dart:convert';
import 'dart:io';

import 'package:beatport_digger/engine/token.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads back a credentials JSON written to disk', () async {
    final dir = await Directory.systemTemp.createTemp('beatport_digger_token_');
    final path = '${dir.path}${Platform.pathSeparator}credentials.json';

    const written = TokenPair(
      accessToken: 'access-token-value',
      refreshToken: 'refresh-token-value',
      expiresIn: 3600,
      tokenType: 'Bearer',
      scope: 'app',
      loginId: '0123456789abcdef',
      issuedAt: 1700000000,
    );

    try {
      final store = FileTokenStore(path);
      await store.write(written);

      final onDisk =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      expect(onDisk['access_token'], 'access-token-value');
      expect(onDisk['login_id'], '0123456789abcdef');

      final token = await store.read();
      expect(token, isNotNull, reason: 'the cache format must parse');
      expect(token!.accessToken, written.accessToken);
      expect(token.refreshToken, written.refreshToken);
      expect(token.loginId, hasLength(16));
      expect(token.expiresIn, greaterThan(0));
      expect(token.issuedAt, greaterThan(0));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
