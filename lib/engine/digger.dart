library;

import 'catalog.dart';
import 'models.dart';

const int defaultCrateLimit = 100;
const int minCrateLimit = 10;
const int maxCrateLimit = 1000;

/// A crate limit of zero means take everything that matches, however many
/// that is.
const int unlimitedCrateLimit = 0;

/// Window size used when taking everything.
///
/// The catalog walk splits a date range until each slice holds no more than
/// this, then reads the slice in one request. Larger slices mean far fewer
/// requests over a long range.
const int exportSliceSize = 500;

/// Beatport's catalog does not go back further than this, so it is where an
/// all-time sweep starts.
final DateTime catalogEpoch = DateTime(2005);

const int defaultWindowDays = 30;
const int maxWindowDays = 3650;

/// Orderings a crate can rank its category by, in the order they are offered.
const Map<String, String> diggerOrderings = {
  '-downloads': 'Most downloaded',
  '-plays': 'Most played',
  '-publish_date': 'Newest first',
  'bpm': 'Slowest first',
  '-bpm': 'Fastest first',
};

/// One dig in a bundle: a filter set, an ordering and how deep to go.
///
/// Crates are built up one at a time and queued together, so each carries its
/// own filters rather than sharing one global set.
class DiggerCrate {
  const DiggerCrate({
    required this.id,
    this.genreId,
    this.genreName,
    this.subGenreId,
    this.subGenreName,
    this.orderBy = '-downloads',
    this.limit = defaultCrateLimit,
    this.windowDays = defaultWindowDays,
    this.bpmLow,
    this.bpmHigh,
    this.isHype = false,
    this.isClassic = false,
    this.isExclusive = false,
  });

  /// Identifies the crate in a bundle. Two crates with identical filters are
  /// still separate entries, so the list is keyed by this rather than by
  /// value.
  final String id;

  final int? genreId;
  final String? genreName;
  final int? subGenreId;
  final String? subGenreName;

  final String orderBy;

  /// How many tracks to take.
  final int limit;

  /// How far back to look. Zero means all time.
  final int windowDays;

  final int? bpmLow;
  final int? bpmHigh;

  final bool isHype;
  final bool isClassic;

  /// Filtered after the fact: Beatport has no exclusive-only query parameter.
  final bool isExclusive;

  /// True when the crate takes everything matching rather than a top slice.
  bool get takesEverything => limit <= unlimitedCrateLimit;

  int get boundedLimit => limit.clamp(minCrateLimit, maxCrateLimit);
  int get boundedWindowDays => windowDays.clamp(0, maxWindowDays);

  /// The range an unlimited crate sweeps. An all-time crate goes back to the
  /// start of the catalog.
  (DateTime, DateTime) rangeFor(DateTime today) {
    final days = boundedWindowDays;
    return days == 0
        ? (catalogEpoch, today)
        : (today.subtract(Duration(days: days)), today);
  }

  String get orderLabel => diggerOrderings[orderBy] ?? orderBy;

  String get windowLabel =>
      boundedWindowDays == 0 ? 'all time' : 'last $boundedWindowDays days';

  /// What the crate is called in the bundle list.
  String get title {
    final sub = subGenreName;
    if (sub != null && sub.isNotEmpty) return '${genreName ?? 'Any'} / $sub';
    return genreName ?? 'Whole catalog';
  }

  /// The filters under the title, as one line.
  String get subtitle {
    final parts = <String>[
      // Ordering only decides which tracks make the cut, so it says nothing
      // useful once the crate takes all of them.
      if (!takesEverything) orderLabel.toLowerCase(),
      windowLabel,
      takesEverything ? 'everything' : 'top $boundedLimit',
    ];
    final bpm = bpmRange;
    if (bpm != null) parts.add('$bpm BPM');
    if (isHype) parts.add('hype');
    if (isClassic) parts.add('classic');
    if (isExclusive) parts.add('exclusive only');
    return parts.join(' · ');
  }

  String? get bpmRange {
    if (bpmLow == null && bpmHigh == null) return null;
    return '${bpmLow ?? ''}-${bpmHigh ?? ''}';
  }

  DiggerCrate copyWith({String? id}) => DiggerCrate(
    id: id ?? this.id,
    genreId: genreId,
    genreName: genreName,
    subGenreId: subGenreId,
    subGenreName: subGenreName,
    orderBy: orderBy,
    limit: limit,
    windowDays: windowDays,
    bpmLow: bpmLow,
    bpmHigh: bpmHigh,
    isHype: isHype,
    isClassic: isClassic,
    isExclusive: isExclusive,
  );

  /// The catalog query for this crate.
  ///
  /// [today] is passed in rather than read from the clock so a window is
  /// reproducible.
  TrackQuery query({required DateTime today}) {
    final days = boundedWindowDays;
    return TrackQuery(
      genreId: genreId == null ? null : [genreId!],
      subGenreId: subGenreId == null ? null : [subGenreId!],
      bpm: bpmLow == null && bpmHigh == null
          ? null
          : '${bpmLow ?? ''}:${bpmHigh ?? ''}',
      newReleaseDate: days == 0
          ? null
          : '${isoDate(today.subtract(Duration(days: days)))}:'
                '${isoDate(today)}',
      isHype: isHype ? true : null,
      isClassic: isClassic ? true : null,
      orderBy: orderBy,
      // For an unlimited crate this is the date-slice threshold rather than a
      // page size; the walk rewrites the date range as it subdivides.
      perPage: takesEverything
          ? exportSliceSize
          : (boundedLimit < discoveryPerPage ? boundedLimit : discoveryPerPage),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    if (genreId != null) 'genre_id': genreId,
    if (genreName != null) 'genre_name': genreName,
    if (subGenreId != null) 'sub_genre_id': subGenreId,
    if (subGenreName != null) 'sub_genre_name': subGenreName,
    'order_by': orderBy,
    'limit': limit,
    'window_days': windowDays,
    if (bpmLow != null) 'bpm_low': bpmLow,
    if (bpmHigh != null) 'bpm_high': bpmHigh,
    if (isHype) 'hype': true,
    if (isClassic) 'classic': true,
    if (isExclusive) 'exclusive': true,
  };

  static DiggerCrate? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;

    int? asInt(Object? raw) => raw is num ? raw.toInt() : null;
    String? asString(Object? raw) =>
        raw is String && raw.isNotEmpty ? raw : null;

    final order = json['order_by'];
    final limit = asInt(json['limit']);
    final window = asInt(json['window_days']);

    return DiggerCrate(
      id: id,
      genreId: asInt(json['genre_id']),
      genreName: asString(json['genre_name']),
      subGenreId: asInt(json['sub_genre_id']),
      subGenreName: asString(json['sub_genre_name']),
      orderBy: order is String && diggerOrderings.containsKey(order)
          ? order
          : '-downloads',
      limit: limit ?? defaultCrateLimit,
      windowDays: window ?? defaultWindowDays,
      bpmLow: asInt(json['bpm_low']),
      bpmHigh: asInt(json['bpm_high']),
      isHype: json['hype'] == true,
      isClassic: json['classic'] == true,
      isExclusive: json['exclusive'] == true,
    );
  }
}

/// Steers a dig that is already running.
///
/// Removing a crate from the bundle drops it only if its turn has not come
/// yet. Once a crate is being walked, the walk holds it, so stopping that one
/// without abandoning the rest of the bundle needs a signal it can see.
class DiggerControl {
  final Set<String> _skipped = {};

  /// Asks the dig to stop collecting from [crateId] and move on. Tracks
  /// already queued from it stay queued.
  void skip(String crateId) => _skipped.add(crateId);

  bool isSkipped(String crateId) => _skipped.contains(crateId);

  void reset() => _skipped.clear();
}

/// Where a dig has got to.
class DiggerStep {
  const DiggerStep({
    required this.index,
    required this.total,
    required this.crate,
  });

  final int index;
  final int total;
  final DiggerCrate crate;

  String get label => '${crate.title} (${index + 1} of $total)';
}

class Digger {
  Digger(this.catalog);

  final Catalog catalog;

  /// Walks each crate in turn and emits its tracks.
  ///
  /// [crates] is read live rather than copied, so a crate added while the dig
  /// is running is picked up when its turn comes and one removed is dropped.
  /// Crates are tracked by identity, which keeps that correct even as the list
  /// is reordered underneath.
  ///
  /// A crate that fails is handed to [onFailure] and skipped rather than
  /// ending the dig, so one rate-limited category does not cost the rest.
  Stream<Track> dig(
    List<DiggerCrate> crates, {
    DateTime? today,
    DiggerControl? control,
    void Function(DiggerStep)? onStep,
    void Function(DiggerCrate, Object)? onFailure,
  }) async* {
    final day = today ?? DateTime.now();
    final done = <String>{};
    var index = 0;

    while (true) {
      DiggerCrate? crate;
      for (final candidate in crates) {
        if (!done.contains(candidate.id)) {
          crate = candidate;
          break;
        }
      }
      if (crate == null) return;
      if (control?.isSkipped(crate.id) ?? false) {
        done.add(crate.id);
        continue;
      }

      done.add(crate.id);
      onStep?.call(
        DiggerStep(index: index, total: crates.length, crate: crate),
      );
      index += 1;

      try {
        // Deliberately not `yield*`: that forwards a sub-stream error straight
        // to the listener, past the catch below, and one bad crate would end
        // the whole dig. `await for` throws into this frame instead.
        await for (final track in _tracksFor(crate, day)) {
          // Breaking here cancels the paged read, so a crate that has already
          // given enough stops fetching rather than running to its limit.
          if (control?.isSkipped(crate.id) ?? false) break;
          if (crate.isExclusive && !track.isExclusive) continue;
          yield track;
        }
      } on Object catch (exception) {
        onFailure?.call(crate, exception);
      }
    }
  }

  /// The tracks one crate covers.
  ///
  /// A top-N crate is a straight paged read. An unlimited one goes through the
  /// date-splitting sweep instead, because a single paged query cannot reach
  /// past Beatport's 10,000 row window however many pages you ask for; the
  /// sweep subdivides the date range until each slice fits and so has no
  /// ceiling.
  Stream<Track> _tracksFor(DiggerCrate crate, DateTime today) {
    final query = crate.query(today: today);
    if (!crate.takesEverything) {
      return catalog.iterTracks(query, limit: crate.boundedLimit);
    }
    final (from, to) = crate.rangeFor(today);
    return catalog.exportTracks(query, from, to);
  }
}
