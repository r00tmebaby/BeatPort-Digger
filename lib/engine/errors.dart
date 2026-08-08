library;

import 'dart:convert';

class BeatportException implements Exception {
  BeatportException(this.status, [this.message = '']);

  final int status;
  final String message;

  @override
  String toString() =>
      'request failed with status $status${message.isEmpty ? '' : ' - $message'}';
}

class AuthException extends BeatportException {
  AuthException(super.status, [super.message]);
}

/// Statuses that are worth sending again after a pause: the request was not
/// wrong, the server was busy or briefly unhealthy.
const Set<int> retryableStatuses = {429, 500, 502, 503, 504};

/// Words that mark a refusal as being about the bearer token itself.
const List<String> _credentialHints = [
  'token',
  'credential',
  'not authenticated',
  'authentication',
  'signature',
];

/// Words that mark a refusal as being about what the account may have. These
/// win over [_credentialHints], so a message like "your subscription expired"
/// is never mistaken for an expired token.
const List<String> _entitlementHints = [
  'subscription',
  'permission',
  'not allowed',
  'entitle',
  'region',
  'territory',
];

/// Decides whether a refused response is about the caller's token, as opposed
/// to what the account is allowed to have.
///
/// Beatport answers both cases with a 4xx, and the difference is expensive:
/// its refresh tokens are single-use, so refreshing on an entitlement refusal
/// spends one for nothing. A bulk download produces a steady stream of 403s
/// for tracks the account does not own, which is enough to churn through the
/// refresh chain and leave the session unrecoverable.
///
/// A 401 is always taken at face value. A 403 counts only when it carries an
/// authentication challenge or says outright that the token is the problem;
/// anything else is treated as an entitlement refusal, which the download path
/// already handles by falling back to the sample.
bool isCredentialFailure(int status, String body, [String? wwwAuthenticate]) {
  if (status == 401) return true;
  if (status != 403) return false;

  final message = errorMessage(body).toLowerCase();
  if (_entitlementHints.any(message.contains)) return false;
  if (wwwAuthenticate != null && wwwAuthenticate.trim().isNotEmpty) return true;
  if (message.isEmpty) return false;
  return _credentialHints.any(message.contains);
}

String errorMessage(String body) {
  Object? payload;
  try {
    payload = jsonDecode(body);
  } on FormatException {
    return '';
  }

  if (payload is! Map<String, dynamic>) {
    return '';
  }

  for (final key in ['detail', 'error', 'error_description']) {
    final value = payload[key];
    if (value is String) {
      return value;
    }
  }

  final parts = <String>[];
  for (final field in payload.keys.toList()..sort()) {
    final value = payload[field];
    if (value is List && value.every((v) => v is String)) {
      parts.add('$field: ${value.join(' ')}');
    }
  }
  return parts.join('; ');
}
