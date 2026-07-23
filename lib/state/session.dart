/// Authentication state shared by every screen.
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

  /// Cached sub-genres for a genre, or null if not loaded yet.
  List<Named>? subGenresFor(int genreId) => _subGenres[genreId];

  /// Reuses a cached token so a returning user is not asked to log in again.
  Future<void> restore() async {
    try {
      final cached = await _auth.loadCached();
      status = cached == null ? SessionStatus.signedOut : SessionStatus.signedIn;
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
      // A rejected login is the common case; say so rather than showing the
      // raw status line.
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

  /// Populates genres and sub-genres from the on-disk cache immediately, then
  /// refreshes from the network in the background.
  ///
  /// The cached data is shown at once so the filters are usable on launch; the
  /// refresh updates them a moment later if anything changed. A first run with
  /// no cache falls straight through to the network.
  Future<void> loadReference() async {
    if (_genres.isEmpty) {
      final cached = await _reference.load();
      if (!cached.isEmpty) {
        _applyReference(cached);
      }
    }
    // Fire and forget: the UI is already usable from cache.
    unawaited(_refreshReference());
  }

  Future<void> _refreshReference() async {
    try {
      final fresh = await _reference.refresh();
      _applyReference(fresh);
    } on Object {
      // A failed refresh leaves the cached data in place.
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
