package com.r00tme.beatportdigger

import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private val channelName = "beatport_digger/mediastore"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "publishAudio" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val relativeDir = call.argument<String>("relativeDir")
                            ?: "Music/BeatPort Digger"
                        val displayName = call.argument<String>("displayName")
                        if (sourcePath == null || displayName == null) {
                            result.error(
                                "args",
                                "sourcePath and displayName are required",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(
                                publishAudio(sourcePath, relativeDir, displayName),
                            )
                        } catch (e: Exception) {
                            result.error("publish_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Copies the file at [sourcePath] into the shared audio collection under
    /// [relativeDir] (for example "Music/BeatPort Digger") using MediaStore, so it
    /// is visible to the Files app and other apps. Returns the public path.
    private fun publishAudio(
        sourcePath: String,
        relativeDir: String,
        displayName: String,
    ): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Below Android 10 there is no scoped MediaStore path; leave the file
            // where it is and let the caller keep the app-storage location.
            throw IOException("MediaStore publishing needs Android 10 or newer")
        }

        val source = File(sourcePath)
        if (!source.exists()) throw IOException("source file is missing")

        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Audio.Media
            .getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Audio.Media.MIME_TYPE, mimeFor(displayName))
            put(MediaStore.Audio.Media.RELATIVE_PATH, relativeDir)
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }

        val item = resolver.insert(collection, values)
            ?: throw IOException("could not create a media entry")

        resolver.openOutputStream(item)?.use { output ->
            source.inputStream().use { it.copyTo(output) }
        } ?: throw IOException("could not open the media entry for writing")

        values.clear()
        values.put(MediaStore.Audio.Media.IS_PENDING, 0)
        resolver.update(item, values, null, null)

        // Resolve the on-disk path so the app can read the file back for
        // playback; the app can read its own media contributions directly.
        var absolutePath: String? = null
        resolver.query(
            item,
            arrayOf(MediaStore.Audio.Media.DATA),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) absolutePath = cursor.getString(0)
        }
        return absolutePath ?: "$relativeDir/$displayName"
    }

    private fun mimeFor(name: String): String = when {
        name.endsWith(".m4a", true) -> "audio/mp4"
        name.endsWith(".aac", true) -> "audio/aac"
        name.endsWith(".mp3", true) -> "audio/mpeg"
        name.endsWith(".flac", true) -> "audio/flac"
        name.endsWith(".wav", true) -> "audio/wav"
        name.endsWith(".ogg", true) -> "audio/ogg"
        else -> "audio/*"
    }
}
