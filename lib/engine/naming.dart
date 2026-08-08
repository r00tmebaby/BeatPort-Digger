library;

import 'models.dart';

const String unknownValue = 'Unknown';

const Map<String, String> templateFields = {
  'artists': 'Track artists',
  'title': 'Title with mix name',
  'name': 'Title without mix name',
  'mix': 'Mix name',
  'genre': 'Genre',
  'subgenre': 'Sub-genre, or genre when absent',
  'key': 'Camelot code, e.g. 8A',
  'key_name': 'Key name, e.g. A Minor',
  'bpm': 'Exact BPM',
  'bpm5': 'BPM bucketed to 5, e.g. 125-129',
  'bpm10': 'BPM bucketed to 10, e.g. 120-129',
  'label': 'Record label',
  'year': 'Release year',
  'date': 'Release date',
  'isrc': 'ISRC',
  'id': 'Track id',
};

const Map<String, String> folderPresets = {
  'All in one folder': '',
  'Genre': '{genre}',
  'Genre / BPM': '{genre}/{bpm10}',
  'Genre / Key': '{genre}/{key}',
  'Key / BPM': '{key}/{bpm10}',
  'BPM / Key': '{bpm10}/{key}',
  'Label': '{label}',
  'Artist': '{artists}',
  'Genre / Label': '{genre}/{label}',
};

String bpmBucket(int? bpm, int size) {
  if (bpm == null || bpm <= 0) return unknownValue;
  final low = (bpm ~/ size) * size;
  return '$low-${low + size - 1}';
}

String _year(Track track) {
  final raw = track.newReleaseDate ?? track.publishDate;
  if (raw == null || raw.length < 4) return unknownValue;
  return raw.substring(0, 4);
}

Map<String, String> templateValues(Track track) {
  final key = track.key;
  return {
    'artists': track.artistNames,
    'title': track.title,
    'name': track.name ?? '',
    'mix': track.mixName ?? '',
    'genre': track.genreName,
    'subgenre': track.subGenreName.isEmpty
        ? track.genreName
        : track.subGenreName,
    'key': key?.camelot ?? '',
    'key_name': key?.name ?? '',
    'bpm': track.bpm?.toString() ?? '',
    'bpm5': bpmBucket(track.bpm, 5),
    'bpm10': bpmBucket(track.bpm, 10),
    'label': track.labelName,
    'year': _year(track),
    'date': track.newReleaseDate ?? track.publishDate ?? '',
    'isrc': track.isrc ?? '',
    'id': track.id?.toString() ?? '',
  };
}

final RegExp _placeholder = RegExp(r'\{(\w+)\}');

String renderTemplate(String template, Map<String, String> values) =>
    template.replaceAllMapped(_placeholder, (match) {
      final field = match.group(1)!;
      if (!values.containsKey(field)) return match.group(0)!;
      final value = values[field]!.trim();
      return value.isEmpty ? unknownValue : value;
    });

List<String> folderSegments(String template, Track track) {
  if (template.trim().isEmpty) return const [];
  final values = templateValues(track);

  final segments = <String>[];
  for (final part in template.split(RegExp(r'[/\\]'))) {
    final segment = sanitizeSegment(renderTemplate(part, values));
    if (segment.isEmpty) continue;

    // A repeated level is never what was meant. It happens because
    // {subgenre} falls back to the genre, so "{genre}/{subgenre}" on a track
    // with no sub-genre would otherwise nest the genre inside itself.
    if (segments.isNotEmpty &&
        segments.last.toLowerCase() == segment.toLowerCase()) {
      continue;
    }
    segments.add(segment);
  }
  return segments;
}

final RegExp _illegal = RegExp(r'[<>:"|?*\x00-\x1f/\\]');
final RegExp _whitespace = RegExp(r'\s+');

String sanitizeSegment(String value) {
  var cleaned = value
      .replaceAll(_illegal, '')
      .replaceAll(_whitespace, ' ')
      .trim();

  cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');

  const reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  if (reserved.contains(cleaned.toUpperCase())) cleaned = '_$cleaned';
  if (cleaned.length > 120) cleaned = cleaned.substring(0, 120).trim();
  return cleaned;
}
