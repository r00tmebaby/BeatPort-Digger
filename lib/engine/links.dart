library;

enum LinkType { track, release, playlist, chart, label, artist }

class BeatportLink {
  const BeatportLink({
    required this.type,
    required this.id,
    this.query = const {},
  });

  final LinkType type;
  final int id;

  final Map<String, String> query;

  @override
  String toString() => '${type.name}:$id';

  @override
  bool operator ==(Object other) =>
      other is BeatportLink && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);
}

class LinkException implements Exception {
  LinkException(this.message);

  final String message;

  @override
  String toString() => message;
}

const Set<String> _hosts = {
  'www.beatport.com',
  'beatport.com',
  'api.beatport.com',
};

const Map<String, (LinkType, int)> _routes = {
  'track': (LinkType.track, 1),
  'tracks': (LinkType.track, 0),
  'release': (LinkType.release, 1),
  'releases': (LinkType.release, 0),
  'label': (LinkType.label, 1),
  'labels': (LinkType.label, 0),
  'artist': (LinkType.artist, 1),
  'artists': (LinkType.artist, 0),

  'chart': (LinkType.chart, 1),
  'charts': (LinkType.chart, 0),
  'playlist': (LinkType.chart, 1),
  'playlists': (LinkType.playlist, 0),
};

BeatportLink parseBeatportLink(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) throw LinkException('Enter a Beatport link.');

  final Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } on FormatException {
    throw LinkException('That is not a valid URL.');
  }

  if (!_hosts.contains(uri.host.toLowerCase())) {
    throw LinkException('Only beatport.com links are supported.');
  }

  var segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  if (segments.length > 1 && segments.first.length == 2) {
    segments = segments.sublist(1);
  }
  if (segments.length > 1 && segments.first == 'catalog') {
    segments = segments.sublist(1);
  }

  if (segments.length > 1 && segments.first == 'library') {
    segments = segments.sublist(1);
    if (segments.first == 'playlist') segments[0] = 'playlists';
  }

  if (segments.isEmpty) throw LinkException('That link has no path.');

  final route = _routes[segments.first.toLowerCase()];
  if (route == null) {
    throw LinkException('Unsupported link type "${segments.first}".');
  }

  final (type, offset) = route;
  final index = 1 + offset;

  if (index >= segments.length) {
    throw LinkException('That link does not include an id.');
  }

  final id = int.tryParse(segments[index]);
  if (id == null) {
    throw LinkException('"${segments[index]}" is not a valid id.');
  }

  return BeatportLink(type: type, id: id, query: uri.queryParameters);
}

bool isBeatportLink(String input) {
  try {
    parseBeatportLink(input);
    return true;
  } on LinkException {
    return false;
  }
}
