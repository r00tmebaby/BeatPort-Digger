import 'dart:io';

import 'package:beatport_digger/engine/atomic_write.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('bpdl-atomic'));
  tearDown(() => dir.deleteSync(recursive: true));

  File target() => File('${dir.path}${Platform.pathSeparator}data.json');

  test('writes a new file and leaves no temp behind', () async {
    await writeFileAtomically(target(), '{"a":1}');

    expect(target().readAsStringSync(), '{"a":1}');
    expect(File('${target().path}.tmp').existsSync(), isFalse);
  });

  test('replaces an existing file in one step', () async {
    await writeFileAtomically(target(), 'old contents');
    await writeFileAtomically(target(), 'new contents');

    expect(target().readAsStringSync(), 'new contents');
    expect(File('${target().path}.tmp').existsSync(), isFalse);
  });

  test('creates missing parent directories', () async {
    final nested = File(
      '${dir.path}${Platform.pathSeparator}a'
      '${Platform.pathSeparator}b${Platform.pathSeparator}c.json',
    );
    await writeFileAtomically(nested, 'x');
    expect(nested.readAsStringSync(), 'x');
  });

  test(
    'a stale temp from an interrupted write is simply overwritten',
    () async {
      // What a crash mid-write leaves behind: a half-finished sibling and the
      // previous good file untouched.
      await writeFileAtomically(target(), 'good');
      File('${target().path}.tmp').writeAsStringSync('half-writ');

      await writeFileAtomically(target(), 'newer');
      expect(target().readAsStringSync(), 'newer');
      expect(File('${target().path}.tmp').existsSync(), isFalse);
    },
  );
}
