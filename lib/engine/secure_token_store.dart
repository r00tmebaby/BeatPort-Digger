/// Keychain-backed token storage for the Flutter app.
///
/// Kept out of token.dart so that file stays free of Flutter plugins and can be
/// reused by the pure-Dart backend server.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token.dart';

/// Keeps the token in the platform keychain.
///
/// Only the token is persisted, never the password, and the keychain keeps it
/// out of a plain file that a backup or sync tool would pick up.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _key = 'beatport_token';

  final FlutterSecureStorage _storage;

  @override
  Future<TokenPair?> read() async {
    String? raw;
    try {
      raw = await _storage.read(key: _key);
    } on Exception {
      // A keychain that cannot be opened is treated as empty: logging in again
      // is a better outcome than refusing to start.
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      return TokenPair.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(TokenPair token) =>
      _storage.write(key: _key, value: jsonEncode(token.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
