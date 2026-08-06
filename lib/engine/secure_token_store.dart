library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token.dart';

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
