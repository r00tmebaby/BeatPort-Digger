/// Locating ffmpeg, and fetching it when the machine does not have it.
///
/// Remuxing needs ffmpeg, which most machines do not ship. Rather than send the
/// user away to install it, a pinned build can be downloaded into the app's own
/// support directory, leaving the rest of the system untouched.
///
/// The build is pinned by version and checked against a hard-coded SHA-256. The
/// digest is what makes this safe to do automatically: without it the app would
/// execute whatever the URL happened to return.
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// A build of ffmpeg that can be fetched for one platform.
class FfmpegRelease {
  const FfmpegRelease({
    required this.version,
    required this.url,
    required this.sha256,
    required this.archiveEntry,
    required this.executable,
  });

  final String version;
  final String url;

  /// Expected SHA-256 of the downloaded archive, lower-case hex.
  final String sha256;

  /// Path of the ffmpeg binary inside the archive.
  final String archiveEntry;

  /// File name to install it under.
  final String executable;
}

/// Builds known to be fetchable, by [Platform.operatingSystem].
///
/// Only Windows is listed. The static builds published for macOS and Linux do
/// not have stable versioned URLs to pin a digest against, so those platforms
/// are asked to install ffmpeg themselves rather than be handed an unverifiable
/// binary.
const Map<String, FfmpegRelease> ffmpegReleases = {
  'windows': FfmpegRelease(
    version: '8.1.2',
    url:
        'https://www.gyan.dev/ffmpeg/builds/packages/'
        'ffmpeg-8.1.2-essentials_build.zip',
    sha256: 'db580001caa24ac104c8cb856cd113a87b0a443f7bdf47d8c12b1d740584a2ec',
    archiveEntry: 'ffmpeg-8.1.2-essentials_build/bin/ffmpeg.exe',
    executable: 'ffmpeg.exe',
  ),
};

class FfmpegException implements Exception {
  FfmpegException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Stage of an in-progress install, for the UI to report.
enum InstallStage { downloading, verifying, extracting, done }

class InstallProgress {
  const InstallProgress({
    required this.stage,
    this.received = 0,
    this.total = 0,
  });

  final InstallStage stage;
  final int received;
  final int total;

  double get fraction => total <= 0 ? 0 : received / total;
}

/// Finds ffmpeg, and installs it on request.
class Ffmpeg {
  Ffmpeg({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;
  String? _resolved;

  void close() => _http.close();

  /// Whether a build can be fetched for the current platform.
  bool get canInstall => ffmpegReleases.containsKey(Platform.operatingSystem);

  /// Where an app-managed copy lives.
  Future<File> managedBinary() async {
    final release = ffmpegReleases[Platform.operatingSystem];
    final name =
        release?.executable ?? (Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg');
    final support = await getApplicationSupportDirectory();
    final separator = Platform.pathSeparator;
    return File('${support.path}${separator}ffmpeg$separator$name');
  }

  /// Returns a usable ffmpeg path, or null if none is available.
  ///
  /// An app-managed copy wins over one on PATH: if a previous run installed it,
  /// that is the build whose digest was checked.
  Future<String?> resolve() async {
    if (_resolved != null) return _resolved;

    final managed = await managedBinary();
    if (await managed.exists() && await _runs(managed.path)) {
      return _resolved = managed.path;
    }
    if (await _runs('ffmpeg')) return _resolved = 'ffmpeg';
    return null;
  }

  Future<bool> _runs(String path) async {
    try {
      final result = await Process.run(path, ['-version']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Downloads, verifies and installs the pinned build, returning its path.
  ///
  /// The archive is streamed to disk rather than buffered: the Windows build is
  /// over 100 MB and holding it in memory alongside its extracted contents is
  /// avoidable.
  Future<String> install({void Function(InstallProgress)? onProgress}) async {
    final release = ffmpegReleases[Platform.operatingSystem];
    if (release == null) {
      throw FfmpegException(
        'No verified ffmpeg build is available for '
        '${Platform.operatingSystem}. Install ffmpeg and make sure it is on '
        'your PATH.',
      );
    }

    final target = await managedBinary();
    await target.parent.create(recursive: true);
    final archive = File(
      '${target.parent.path}${Platform.pathSeparator}'
      'ffmpeg-${release.version}.zip.part',
    );

    try {
      await _download(release, archive, onProgress);

      onProgress?.call(const InstallProgress(stage: InstallStage.verifying));
      final digest = await _sha256(archive);
      if (digest != release.sha256) {
        throw FfmpegException(
          'The downloaded ffmpeg archive did not match its expected checksum '
          'and was discarded. Expected ${release.sha256}, got $digest.',
        );
      }

      onProgress?.call(const InstallProgress(stage: InstallStage.extracting));
      await _extract(archive, release, target);
    } finally {
      // The partial archive is large; do not leave it behind on failure.
      if (await archive.exists()) {
        await archive.delete().catchError((_) => archive);
      }
    }

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', target.path]);
    }

    if (!await _runs(target.path)) {
      throw FfmpegException('The installed ffmpeg could not be run.');
    }

    onProgress?.call(const InstallProgress(stage: InstallStage.done));
    return _resolved = target.path;
  }

  Future<void> _download(
    FfmpegRelease release,
    File destination,
    void Function(InstallProgress)? onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(release.url));
    final response = await _http.send(request);
    if (response.statusCode != 200) {
      throw FfmpegException(
        'Downloading ffmpeg failed with status ${response.statusCode}.',
      );
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = destination.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          InstallProgress(
            stage: InstallStage.downloading,
            received: received,
            total: total,
          ),
        );
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Pulls the single ffmpeg binary out of the archive.
  ///
  /// Only the one known entry is extracted, so a tampered archive cannot write
  /// to paths of its choosing.
  Future<void> _extract(
    File archive,
    FfmpegRelease release,
    File target,
  ) async {
    final input = InputFileStream(archive.path);
    try {
      final zip = ZipDecoder().decodeStream(input);
      for (final entry in zip.files) {
        if (!entry.isFile || entry.name != release.archiveEntry) continue;
        final output = OutputFileStream(target.path);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        return;
      }
      throw FfmpegException(
        'The ffmpeg archive did not contain ${release.archiveEntry}.',
      );
    } finally {
      await input.close();
    }
  }
}
