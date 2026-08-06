library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'catalog.dart';
import 'models.dart';

class ReferenceData {
  const ReferenceData({
    required this.genres,
    required this.subGenres,
    required this.keys,
    required this.fetchedAt,
  });

  final List<Genre> genres;

  final Map<int, List<Named>> subGenres;
  final List<Key> keys;
  final DateTime? fetchedAt;

  bool get isEmpty => genres.isEmpty && keys.isEmpty;

  Map<String, dynamic> toJson() => {
    'fetched_at': fetchedAt?.toIso8601String(),
    'genres': [
      for (final g in genres) {'id': g.id, 'name': g.name, 'slug': g.slug},
    ],
    'sub_genres': {
      for (final entry in subGenres.entries)
        '${entry.key}': [
          for (final s in entry.value)
            {'id': s.id, 'name': s.name, 'slug': s.slug},
        ],
    },
    'keys': [
      for (final k in keys)
        {
          'id': k.id,
          'name': k.name,
          'camelot_number': k.camelotNumber,
          'camelot_letter': k.camelotLetter,
        },
    ],
  };

  factory ReferenceData.fromJson(Map<String, dynamic> json) {
    final rawSubs = json['sub_genres'];
    final subs = <int, List<Named>>{};
    if (rawSubs is Map<String, dynamic>) {
      rawSubs.forEach((key, value) {
        final id = int.tryParse(key);
        if (id != null && value is List) {
          subs[id] = value
              .whereType<Map<String, dynamic>>()
              .map(Named.fromJson)
              .toList();
        }
      });
    }
    final rawFetched = json['fetched_at'];
    return ReferenceData(
      genres: (json['genres'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Genre.fromJson)
          .toList(),
      subGenres: subs,
      keys: (json['keys'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Key.fromJson)
          .toList(),
      fetchedAt: rawFetched is String ? DateTime.tryParse(rawFetched) : null,
    );
  }
}

class ReferenceCache {
  ReferenceCache(this.catalog);

  final Catalog catalog;

  Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}${Platform.pathSeparator}reference.json');
  }

  Future<ReferenceData> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return _empty;
      final payload = jsonDecode(await file.readAsString());
      if (payload is! Map<String, dynamic>) return _empty;
      return ReferenceData.fromJson(payload);
    } on Object {
      return _empty;
    }
  }

  Future<ReferenceData> refresh({DateTime? now}) async {
    final genres = await catalog.genres();
    final keys = await catalog.allKeys();

    final subs = <int, List<Named>>{};
    for (final genre in genres) {
      final id = genre.id;
      if (id == null) continue;
      try {
        subs[id] = await catalog.subGenres(id);
      } on Object {
        // Best-effort: skip this genre's sub-genres rather than fail the
        // whole reference refresh over one bad lookup.
      }
    }

    final data = ReferenceData(
      genres: genres,
      subGenres: subs,
      keys: keys,
      fetchedAt: now,
    );
    await _save(data);
    return data;
  }

  Future<void> _save(ReferenceData data) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(data.toJson()));
    } on Object {
      // Best-effort cache write; a failed save just means we refetch later.
    }
  }

  static const ReferenceData _empty = ReferenceData(
    genres: [],
    subGenres: {},
    keys: [],
    fetchedAt: null,
  );
}
