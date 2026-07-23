/// HTTP transport for the Beatport v4 catalog API.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'errors.dart';

class BeatportClient {
  BeatportClient({required this.auth, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final Authenticator auth;
  final http.Client _http;

  void close() => _http.close();

  Future<http.Response> _send(String path, Map<String, String> params) {
    final token = auth.token;
    if (token == null) {
      throw AuthException(401, 'client is not authenticated');
    }
    final uri = Uri.parse(
      '$baseUrl$path',
    ).replace(queryParameters: params.isEmpty ? null : params);
    return _http.get(uri, headers: {
      ...defaultHeaders,
      'Authorization': '${token.tokenType} ${token.accessToken}',
    });
  }

  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, Object?> params = const {},
  ]) async {
    final cleaned = <String, String>{};
    params.forEach((key, value) {
      if (value == null) return;
      final text = value.toString();
      if (text.isEmpty) return;
      cleaned[key] = text;
    });

    await auth.check();
    var response = await _send(path, cleaned);

    // One retry: a token can be rejected before its recorded expiry.
    if (response.statusCode == 401) {
      if (!await auth.refresh()) {
        throw AuthException(401, 'session expired, log in again');
      }
      response = await _send(path, cleaned);
    }

    if (response.statusCode != 200) {
      throw BeatportException(response.statusCode, errorMessage(response.body));
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
