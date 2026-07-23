/// The OAuth token pair, its fingerprint, and where it is cached.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The client identifier the Beatport web player presents. Its authorization
/// code grant takes no secret, so a username and password are enough to issue a
/// token pair without registering an OAuth application.
const String publicClientId = 'ryZ8LuyQVPqbK2mBX2Hwt4qSMtnWuTYSqBPO92yQ';

/// Renew this many seconds before the recorded expiry, so a token cannot lapse
/// midway through a long export.
const int refreshLeeway = 300;

// 64-bit FNV-1a over "username:password", giving a stable login_id that ties a
// cached token to the account it was issued for without storing the password.
final BigInt _fnvOffset = BigInt.parse('cbf29ce484222325', radix: 16);
final BigInt _fnvPrime = BigInt.parse('100000001b3', radix: 16);
final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

/// Fingerprints a credential pair so a cached token can be tied to it.
///
/// Lets a cache issued for one account be discarded when another logs in,
/// without storing the password itself.
String computeLoginId(String username, String password) {
  var digest = _fnvOffset;
  for (final byte in utf8.encode('$username:$password')) {
    digest = (digest ^ BigInt.from(byte));
    digest = (digest * _fnvPrime) & _mask64;
  }
  return digest.toRadixString(16).padLeft(16, '0');
}

class TokenPair {
  const TokenPair({
    required this.accessToken,
    this.refreshToken,
    this.expiresIn = 0,
    this.tokenType = 'Bearer',
    this.scope = '',
    this.loginId = '',
    this.issuedAt = 0,
  });

  final String accessToken;
  final String? refreshToken;
  final int expiresIn;
  final String tokenType;
  final String scope;
  final String loginId;
  final int issuedAt;

  factory TokenPair.fromJson(Map<String, dynamic> json) => TokenPair(
    accessToken: json['access_token'] as String? ?? '',
    refreshToken: json['refresh_token'] as String?,
    expiresIn: (json['expires_in'] as num?)?.toInt() ?? 0,
    tokenType: json['token_type'] as String? ?? 'Bearer',
    scope: json['scope'] as String? ?? '',
    loginId: json['login_id'] as String? ?? '',
    issuedAt: (json['issued_at'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_in': expiresIn,
    'token_type': tokenType,
    'scope': scope,
    'login_id': loginId,
    'issued_at': issuedAt,
  };

  int get expiresAt {
    if (issuedAt == 0 || expiresIn == 0) return 0;
    return issuedAt + expiresIn;
  }

  DateTime? get expiresOn => expiresAt == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);

  /// Whether the access token is due for renewal. An unknown issue time counts
  /// as live, since there is nothing to compare against.
  bool isExpired({int leeway = refreshLeeway}) {
    if (expiresAt == 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= (expiresAt - leeway);
  }

  /// A copy carrying the issue time, so expiry can be tracked locally: the
  /// token response states a lifetime, not a deadline.
  TokenPair stamped({String loginId = ''}) => TokenPair(
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresIn: expiresIn,
    tokenType: tokenType,
    scope: scope,
    loginId: loginId.isNotEmpty ? loginId : this.loginId,
    issuedAt: issuedAt != 0
        ? issuedAt
        : DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
}

/// Where the token pair is kept between runs.
abstract class TokenStore {
  Future<TokenPair?> read();
  Future<void> write(TokenPair token);
  Future<void> clear();
}

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

/// Keeps the token in a plain JSON file, used by tests and headless runs where
/// a platform keychain is not available.
class FileTokenStore implements TokenStore {
  FileTokenStore(this.path);

  final String path;

  @override
  Future<TokenPair?> read() async {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return TokenPair.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> write(TokenPair token) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(token.toJson()));
  }

  @override
  Future<void> clear() async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}
