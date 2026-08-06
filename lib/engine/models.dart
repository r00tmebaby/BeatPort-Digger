library;

const String _major = 'B';
const String _minor = 'A';

String? _string(Object? value) => value is String ? value : null;
int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;

class Named {
  const Named({this.id, this.name, this.slug});

  final int? id;
  final String? name;
  final String? slug;

  factory Named.fromJson(Map<String, dynamic> json) => Named(
    id: _int(json['id']),
    name: _string(json['name']),
    slug: _string(json['slug']),
  );
}

class Key {
  const Key({this.id, this.name, this.camelotNumber, this.camelotLetter});

  final int? id;
  final String? name;
  final int? camelotNumber;
  final String? camelotLetter;

  factory Key.fromJson(Map<String, dynamic> json) => Key(
    id: _int(json['id']),
    name: _string(json['name']),
    camelotNumber: _int(json['camelot_number']),
    camelotLetter: _string(json['camelot_letter']),
  );

  String get camelot {
    final number = camelotNumber;
    final letter = camelotLetter;
    if (number == null || letter == null || letter.isEmpty) return '';
    return '$number$letter';
  }

  List<String> neighbours() {
    final number = camelotNumber;
    final rawLetter = camelotLetter;
    if (number == null || rawLetter == null || rawLetter.isEmpty) {
      return const [];
    }
    final letter = rawLetter.toUpperCase();
    final up = number % 12 + 1;
    final down = (number - 2) % 12 + 1;
    final opposite = letter == _major ? _minor : _major;
    return ['$number$letter', '$up$letter', '$down$letter', '$number$opposite'];
  }
}

class Track {
  const Track({
    this.id,
    this.name,
    this.mixName,
    this.slug,
    this.isrc,
    this.bpm,
    this.length,
    this.publishDate,
    this.newReleaseDate,
    this.key,
    this.genre,
    this.subGenre,
    this.artists = const [],
    this.labelName = '',
    this.sampleUrl,
    this.isHype = false,
    this.isExclusive = false,
    this.isClassic = false,
    this.isDjEdit = false,
    this.isExplicit = false,
    this.isPreOrder = false,
  });

  final int? id;
  final String? name;
  final String? mixName;
  final String? slug;
  final String? isrc;
  final int? bpm;
  final String? length;
  final String? publishDate;
  final String? newReleaseDate;
  final Key? key;
  final Named? genre;
  final Named? subGenre;
  final List<Named> artists;
  final String labelName;

  final String? sampleUrl;

  final bool isHype;
  final bool isExclusive;
  final bool isClassic;
  final bool isDjEdit;
  final bool isExplicit;
  final bool isPreOrder;

  factory Track.fromJson(Map<String, dynamic> json) {
    final rawArtists = json['artists'];
    final artists = rawArtists is List
        ? rawArtists
              .whereType<Map<String, dynamic>>()
              .map(Named.fromJson)
              .toList()
        : <Named>[];

    var label = '';
    final release = _map(json['release']);
    if (release != null) {
      label = _string(_map(release['label'])?['name']) ?? '';
    }

    final key = _map(json['key']);
    final genre = _map(json['genre']);
    final subGenre = _map(json['sub_genre']);

    return Track(
      id: _int(json['id']),
      name: _string(json['name']),
      mixName: _string(json['mix_name']),
      slug: _string(json['slug']),
      isrc: _string(json['isrc']),
      bpm: _int(json['bpm']),
      length: _string(json['length']),
      publishDate: _string(json['publish_date']),
      newReleaseDate: _string(json['new_release_date']),
      key: key == null ? null : Key.fromJson(key),
      genre: genre == null ? null : Named.fromJson(genre),
      subGenre: subGenre == null ? null : Named.fromJson(subGenre),
      artists: artists,
      labelName: label,
      sampleUrl: _string(json['sample_url']),
      isHype: json['is_hype'] == true,
      isExclusive: json['exclusive'] == true,
      isClassic: json['is_classic'] == true,
      isDjEdit: json['is_dj_edit'] == true,
      isExplicit: json['is_explicit'] == true,
      isPreOrder: json['pre_order'] == true,
    );
  }

  List<String> get badges => [
    if (isHype) 'Hype',
    if (isExclusive) 'Exclusive',
    if (isClassic) 'Classic',
    if (isDjEdit) 'DJ Edit',
    if (isPreOrder) 'Pre-order',
    if (isExplicit) 'E',
  ];

  String get artistNames =>
      artists.map((a) => a.name).whereType<String>().join(', ');

  String get title {
    final mix = mixName;
    if (mix != null && mix.isNotEmpty) return '${name ?? ''} ($mix)';
    return name ?? '';
  }

  String get genreName => genre?.name ?? '';

  String get subGenreName => subGenre?.name ?? '';

  String get storeUrl {
    if (id == null) return '';
    return 'https://www.beatport.com/track/${slug ?? 'track'}/$id';
  }
}

class TrackStream {
  const TrackStream({required this.url, this.sampleStartMs, this.sampleEndMs});

  final String url;
  final int? sampleStartMs;
  final int? sampleEndMs;

  factory TrackStream.fromJson(Map<String, dynamic> json) => TrackStream(
    url: _string(json['stream_url']) ?? '',
    sampleStartMs: _int(json['sample_start_ms']),
    sampleEndMs: _int(json['sample_end_ms']),
  );
}

class TrackDownload {
  const TrackDownload({required this.location, required this.streamQuality});

  final String location;

  final String streamQuality;

  factory TrackDownload.fromJson(Map<String, dynamic> json) => TrackDownload(
    location: _string(json['location']) ?? '',
    streamQuality: _string(json['stream_quality']) ?? '',
  );

  String get extension => switch (streamQuality) {
    '.flac' => '.flac',
    '.256k.aac.mp4' || '.128k.aac.mp4' => '.m4a',
    _ => '.audio',
  };
}

class Genre {
  const Genre({this.id, this.name, this.slug, this.subGenres = const []});

  final int? id;
  final String? name;
  final String? slug;
  final List<Named> subGenres;

  factory Genre.fromJson(Map<String, dynamic> json) {
    final raw = json['sub_genres'];
    return Genre(
      id: _int(json['id']),
      name: _string(json['name']),
      slug: _string(json['slug']),
      subGenres: raw is List
          ? raw.whereType<Map<String, dynamic>>().map(Named.fromJson).toList()
          : const [],
    );
  }
}

class Paginated<T> {
  const Paginated({
    this.count = 0,
    this.next,
    this.previous,
    this.results = const [],
  });

  final int count;
  final String? next;
  final String? previous;
  final List<T> results;

  factory Paginated.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) item,
  ) {
    final raw = json['results'];
    return Paginated<T>(
      count: _int(json['count']) ?? 0,
      next: _string(json['next']),
      previous: _string(json['previous']),
      results: raw is List
          ? raw.whereType<Map<String, dynamic>>().map(item).toList()
          : const [],
    );
  }
}
