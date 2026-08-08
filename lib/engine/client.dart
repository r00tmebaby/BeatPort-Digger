library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'errors.dart';
import 'request_limiter.dart';

/// How many catalog requests may be in flight at once across the whole app.
const int maxInFlightRequests = 6;

/// Total sends allowed for one logical request, including the first.
const int maxRequestAttempts = 4;

const Duration initialRetryDelay = Duration(milliseconds: 500);
const Duration maxRetryDelay = Duration(seconds: 20);

/// Upper bound on a server-supplied `Retry-After`, so a hostile or mistaken
/// value cannot park a download for an hour.
const Duration maxHonouredRetryAfter = Duration(seconds: 120);

class BeatportClient {
  BeatportClient({
    required this.auth,
    http.Client? httpClient,
    RequestLimiter? limiter,
    Future<void> Function(Duration)? sleep,
    this.maxAttempts = maxRequestAttempts,
    math.Random? jitter,
  }) : _http = httpClient ?? http.Client(),
       _limiter = limiter ?? RequestLimiter(maxInFlightRequests),
       _sleep = sleep ?? _wait,
       _jitter = jitter ?? math.Random();

  final Authenticator auth;
  final http.Client _http;
  final RequestLimiter _limiter;
  final Future<void> Function(Duration) _sleep;
  final math.Random _jitter;

  final int maxAttempts;

  static Future<void> _wait(Duration delay) => Future<void>.delayed(delay);

  void close() => _http.close();

  Future<http.Response> _send(
    String path,
    Map<String, String> params,
    String accessToken,
  ) {
    final uri = Uri.parse(
      '$baseUrl$path',
    ).replace(queryParameters: params.isEmpty ? null : params);

    return _limiter.run(
      () => _http.get(
        uri,
        headers: {...defaultHeaders, 'Authorization': 'Bearer $accessToken'},
      ),
    );
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

    var refreshed = false;
    BeatportException? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await auth.check();

      // Read the generation alongside the token so that if this request comes
      // back 401 we can tell "my token went stale while I was waiting" from
      // "the session is genuinely gone".
      final generation = auth.tokenGeneration;
      final token = auth.token;
      if (token == null) {
        throw AuthException(401, 'client is not authenticated');
      }

      final http.Response response;
      try {
        response = await _send(path, cleaned, token.accessToken);
      } on http.ClientException {
        // A dropped connection mid-walk should not end a 10,000 track queue.
        if (attempt == maxAttempts) rethrow;
        await _sleep(retryDelay(attempt));
        continue;
      }

      final status = response.statusCode;
      if (status == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }

      if (isCredentialFailure(
        status,
        response.body,
        response.headers['www-authenticate'],
      )) {
        if (!refreshed && await auth.refresh(ifGeneration: generation)) {
          refreshed = true;
          continue;
        }
        throw AuthException(status, 'session expired, log in again');
      }

      lastError = BeatportException(status, errorMessage(response.body));
      if (!retryableStatuses.contains(status)) throw lastError;
      if (attempt < maxAttempts) {
        await _sleep(retryDelay(attempt, response.headers['retry-after']));
      }
    }

    throw lastError ?? AuthException(401, 'session expired, log in again');
  }

  /// Delay before send number `attempt + 1`.
  ///
  /// A server-supplied `Retry-After` wins when present. Otherwise the wait
  /// doubles per attempt and carries jitter, because a rate limit hit by
  /// sixteen downloads at once would otherwise release all sixteen at the
  /// same instant and trip straight over it again.
  ///
  /// Only the delta-seconds form of `Retry-After` is read; the HTTP-date form
  /// would pull in `dart:io`, which the web build cannot use, and Beatport
  /// sends seconds.
  Duration retryDelay(int attempt, [String? retryAfter]) {
    final seconds = int.tryParse((retryAfter ?? '').trim());
    if (seconds != null && seconds > 0) {
      return seconds > maxHonouredRetryAfter.inSeconds
          ? maxHonouredRetryAfter
          : Duration(seconds: seconds);
    }

    final steps = math.min(attempt - 1, 20);
    final doubled = initialRetryDelay.inMilliseconds * (1 << steps);
    final capped = math.min(doubled, maxRetryDelay.inMilliseconds);
    final half = capped ~/ 2;
    return Duration(milliseconds: half + _jitter.nextInt(half + 1));
  }
}
