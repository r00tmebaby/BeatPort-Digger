import 'package:beatport_digger/engine/models.dart';
import 'package:beatport_digger/engine/naming.dart';
import 'package:flutter_test/flutter_test.dart';

Track make({
  String? name = 'Track',
  String? mix,
  int? bpm = 127,
  String? genre = 'Techno',
  String? subGenre,
  int? camelotNumber = 8,
  String? camelotLetter = 'A',
  String label = 'Label',
  String? date = '2026-03-14',
  List<String> artists = const ['Artist'],
}) => Track(
  id: 1,
  name: name,
  mixName: mix,
  bpm: bpm,
  newReleaseDate: date,
  key: camelotNumber == null
      ? null
      : Key(
          name: 'A Minor',
          camelotNumber: camelotNumber,
          camelotLetter: camelotLetter,
        ),
  genre: genre == null ? null : Named(name: genre),
  subGenre: subGenre == null ? null : Named(name: subGenre),
  artists: [for (final a in artists) Named(name: a)],
  labelName: label,
);

void main() {
  group('bpmBucket', () {
    test('groups tempos into ranges', () {
      expect(bpmBucket(127, 10), '120-129');
      expect(bpmBucket(127, 5), '125-129');
      expect(bpmBucket(120, 10), '120-129');
      expect(bpmBucket(130, 10), '130-139');
    });

    test('labels a missing or nonsense tempo', () {
      expect(bpmBucket(null, 10), unknownValue);
      expect(bpmBucket(0, 10), unknownValue);
    });
  });

  group('renderTemplate', () {
    test('substitutes known fields', () {
      final values = templateValues(make(mix: 'Extended Mix'));
      expect(renderTemplate('{genre}/{key}', values), 'Techno/8A');
      expect(
        renderTemplate('{artists} - {title}', values),
        'Artist - Track (Extended Mix)',
      );
    });

    test('falls back to a visible folder when a value is missing', () {
      final values = templateValues(make(genre: null));
      expect(renderTemplate('{genre}', values), unknownValue);
    });

    test('leaves an unknown placeholder visible rather than dropping it', () {
      final values = templateValues(make());
      expect(renderTemplate('{nonsense}', values), '{nonsense}');
    });

    test('subgenre falls back to genre', () {
      expect(templateValues(make(subGenre: null))['subgenre'], 'Techno');
      expect(
        templateValues(make(subGenre: 'Peak Time'))['subgenre'],
        'Peak Time',
      );
    });

    test('year comes from the release date', () {
      expect(templateValues(make(date: '2026-03-14'))['year'], '2026');
      expect(templateValues(make(date: null))['year'], unknownValue);
    });
  });

  group('folderSegments', () {
    test('nests on slashes', () {
      expect(folderSegments('{genre}/{bpm10}', make()), ['Techno', '120-129']);
    });

    test('an empty template means no nesting', () {
      expect(folderSegments('', make()), isEmpty);
      expect(folderSegments('   ', make()), isEmpty);
    });

    test('a value containing a slash cannot invent nesting', () {
      expect(folderSegments('{genre}', make(genre: 'Drum & Bass / Jungle')), [
        'Drum & Bass Jungle',
      ]);

      expect(folderSegments('{label}', make(label: r'..\..\Windows')), [
        '....Windows',
      ]);
    });

    test('a template segment that is only dots is dropped', () {
      expect(folderSegments('{genre}/../..', make()), ['Techno']);
    });

    test('drops segments that sanitise to nothing', () {
      expect(folderSegments('{genre}/{label}', make(label: '///')), ['Techno']);
    });

    test('does not nest a genre inside itself', () {
      // {subgenre} falls back to the genre when a track has none, so this
      // template used to produce Techno/Techno for most of a genre sweep.
      expect(folderSegments('{genre}/{subgenre}', make()), ['Techno']);
      expect(
        folderSegments('{genre}/{subgenre}', make(subGenre: 'Peak Time')),
        ['Techno', 'Peak Time'],
      );
    });

    test('a repeat is only collapsed when it is next to itself', () {
      expect(
        folderSegments(
          '{genre}/{bpm10}/{subgenre}',
          make(genre: 'Techno', bpm: 127),
        ),
        ['Techno', '120-129', 'Techno'],
        reason: 'only an immediately duplicated level is the fallback bug',
      );
    });

    test('the collapse ignores case', () {
      expect(
        folderSegments('{genre}/{label}', make(genre: 'Techno', label: 'TECHNO')),
        ['Techno'],
      );
    });
  });

  group('sanitizeSegment', () {
    test('removes characters the filesystem forbids', () {
      expect(sanitizeSegment('A<B>C:D"E|F?G*H'), 'ABCDEFGH');
    });

    test('trims trailing dots and spaces', () {
      expect(sanitizeSegment('name.'), 'name');
      expect(sanitizeSegment('name  '), 'name');
    });

    test('escapes reserved device names', () {
      expect(sanitizeSegment('CON'), '_CON');
      expect(sanitizeSegment('nul'), '_nul');
      expect(sanitizeSegment('CONTROL'), 'CONTROL');
    });

    test('collapses whitespace and caps length', () {
      expect(sanitizeSegment('a    b'), 'a b');
      expect(sanitizeSegment('x' * 200).length, 120);
    });
  });
}
