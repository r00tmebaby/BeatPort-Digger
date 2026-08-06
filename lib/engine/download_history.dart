library;

class HistoryEntry {
  const HistoryEntry({
    required this.trackId,
    required this.title,
    required this.artists,
    required this.path,
    required this.quality,
    required this.completedAt,
    this.present = true,
  });

  final int trackId;
  final String title;
  final String artists;
  final String path;
  final String quality;
  final DateTime completedAt;

  final bool present;

  HistoryEntry copyWith({bool? present}) => HistoryEntry(
    trackId: trackId,
    title: title,
    artists: artists,
    path: path,
    quality: quality,
    completedAt: completedAt,
    present: present ?? this.present,
  );

  Map<String, dynamic> toJson() => {
    'track_id': trackId,
    'title': title,
    'artists': artists,
    'path': path,
    'quality': quality,
    'completed_at': completedAt.toIso8601String(),
  };

  static HistoryEntry? fromJson(Map<String, dynamic> json) {
    final id = json['track_id'];
    final path = json['path'];
    if (id is! int || path is! String) return null;
    return HistoryEntry(
      trackId: id,
      title: json['title'] is String ? json['title'] as String : '',
      artists: json['artists'] is String ? json['artists'] as String : '',
      path: path,
      quality: json['quality'] is String ? json['quality'] as String : '',
      completedAt:
          DateTime.tryParse('${json['completed_at']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

enum HistoryMark { none, saved, missing }
