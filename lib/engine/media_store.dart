/// Publishing finished downloads to shared storage on Android.
///
/// Android's scoped storage forbids writing straight into the shared Music
/// folder, so a completed download is copied there through MediaStore, which
/// makes it visible to the Files app and to other apps such as DJ software.
library;

import 'dart:io';

import 'package:flutter/services.dart';

class MediaStore {
  static const MethodChannel _channel = MethodChannel('beatport_digger/mediastore');

  /// Copies the file at [sourcePath] into the shared audio collection under
  /// [relativeDir] and returns its on-disk path, or null when publishing is
  /// unavailable (not Android, or below Android 10). The source is left in
  /// place for the caller to remove.
  static Future<String?> publishAudio({
    required String sourcePath,
    required String displayName,
    String relativeDir = 'Music/BeatPort Digger',
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('publishAudio', {
        'sourcePath': sourcePath,
        'displayName': displayName,
        'relativeDir': relativeDir,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
