library;

import 'dart:io';

import 'package:flutter/services.dart';

class MediaStore {
  static const MethodChannel _channel = MethodChannel(
    'beatport_digger/mediastore',
  );

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
