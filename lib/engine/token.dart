library;

import 'dart:convert';
import 'dart:io';

import 'atomic_write.dart';

const String publicClientId = 'ryZ8LuyQVPqbK2mBX2Hwt4qSMtnWuTYSqBPO92yQ';

const int refreshLeeway = 300;

final BigInt _fnvOffset = BigInt.parse('cbf29ce484222325', radix: 16);
final BigInt _fnvPrime = BigInt.parse('100000001b3', radix: 16);
final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

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

  bool isExpired({int leeway = refreshLeeway}) {
    if (expiresAt == 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= (expiresAt - leeway);
  }

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

abstract class TokenStore {
  Future<TokenPair?> read();
  Future<void> write(TokenPair token);
  Future<void> clear();
}

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
    // Atomic: a token file truncated mid-write reads as no session at all,
    // which forces a fresh login and burns the refresh chain.
    await writeFileAtomically(File(path), jsonEncode(token.toJson()));
  }

  @override
  Future<void> clear() async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }
}
