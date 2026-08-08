library;

import 'dart:io';

/// Writes [contents] so the file on disk is always either the old version or
/// the new one, never a truncated in-between.
///
/// A plain writeAsString truncates the target before writing, so a process
/// killed mid-write leaves an empty or half file. That is exactly how a
/// session's download history was caught reading zero bytes. Writing to a
/// sibling and renaming it over the target makes the swap the only visible
/// step; a rename within one directory replaces the file in place on every
/// platform the app ships to.
Future<void> writeFileAtomically(File file, String contents) async {
  await file.parent.create(recursive: true);
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(contents, flush: true);
  await temp.rename(file.path);
}
