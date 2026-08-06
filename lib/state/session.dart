library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../engine/auth.dart';
import '../engine/catalog.dart';
import '../engine/client.dart';
import '../engine/errors.dart';
import '../engine/models.dart';
import '../engine/reference_cache.dart';
import '../engine/secure_token_store.dart';
import '../engine/token.dart';

enum SessionStatus { restoring, signedOut, signedIn }

class Session extends ChangeNotifier {
  Session({http.Client? httpClient, TokenStore? store})
    : _http = httpClient ?? http.Client() {
    _auth = Authenticator(
      httpClient: _http,
      store: store ?? SecureTokenStore(),
    );
    catalog = Catalog(BeatportClient(auth: _auth, httpClient: _http));
    _reference = ReferenceCache(catalog);
  }

  final http.Client _http;
  late final Authenticator _auth;
  late final Catalog catalog;
  late final ReferenceCache _reference;

  SessionStatus status = SessionStatus.restoring;
  String? error;
  bool busy = false;

  TokenPair? get token => _auth.token;

  List<Genre> _genres = const [];
  List<Genre> get genres => _genres;

  Map<int, List<Named>> _subGenres = const {};

  List<Named>? subGenresFor(int genreId) => _subGenres[genreId];

  Future<void> restore() async {
    try {
      final cached = await _auth.loadCached();
      status = cached == null
          ? SessionStatus.signedOut
          : SessionStatus.signedIn;
    } on Exception {
      status = SessionStatus.signedOut;
    }
    notifyListeners();
    if (status == SessionStatus.signedIn) {
      await loadReference();
    }
  }

  Future<bool> logIn(String username, String password) async {
    busy = true;
    error = null;
    notifyListeners();

    try {
      await _auth.logIn(username, password);
      status = SessionStatus.signedIn;
      busy = false;
      notifyListeners();
      await loadReference();
      return true;
    } on BeatportException catch (exception) {
      error = exception.status == 401 || exception.status == 400
          ? 'Incorrect username or password.'
          : exception.toString();
    } on Exception catch (exception) {
      error = 'Could not reach Beatport: $exception';
    }

    busy = false;
    notifyListeners();
    return false;
  }

  Future<void> logOut() async {
    await _auth.logOut();
    _genres = const [];
    _subGenres = const {};
    status = SessionStatus.signedOut;
    notifyListeners();
  }

  Future<void> loadReference() async {
    if (_genres.isEmpty) {
      final cached = await _reference.load();
      if (!cached.isEmpty) {
        _applyReference(cached);
      }
    }

    unawaited(_refreshReference());
  }

  Future<void> _refreshReference() async {
    try {
      final fresh = await _reference.refresh();
      _applyReference(fresh);
    } on Object {
      // Best-effort background refresh; keep using the cached data.
    }
  }

  void _applyReference(ReferenceData data) {
    final sorted = List.of(data.genres)
      ..sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
    _genres = sorted;
    _subGenres = data.subGenres;
    notifyListeners();
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}
