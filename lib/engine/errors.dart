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
