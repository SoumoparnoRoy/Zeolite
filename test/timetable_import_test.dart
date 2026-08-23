import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/domain/day_grid.dart';
import 'package:zeolite/domain/timetable_import.dart';

/// The real timetable's day: 9:10–16:30 on 50-minute blocks, so block 1 runs
/// 9:10–10:00 and block 9 is the 40-minute tail.
const DayGrid _grid = DayGrid(
  dayStartMinutes: 9 * 60 + 10,
  dayEndMinutes: 16 * 60 + 30,
  blockMinutes: 50,
);

TimetableImportResult _parse(String text) =>
    TimetableImport.parse(text, grid: _grid);

void main() {
  group('a line off the printed sheet', () {
    test('carries subject, day, time, room and teacher', () {
      final TimetableImportResult result = _parse('ECE1102, Mo, 5, B204, RKM');
      expect(result.hasProblems, isFalse);

      final ImportedClass c = result.classes.single;
      expect(c.subjectName, 'ECE1102');
      expect(c.weekday, DateTime.monday);
      expect(c.startMinutes, 12 * 60 + 30);
      expect(c.endMinutes, 13 * 60 + 20);
      expect(c.room, 'B204');
      expect(c.teacher, 'RKM');
    });

    test('room and teacher are optional', () {
      final ImportedClass c = _parse('Maths, We, 2').classes.single;
      expect(c.room, isNull);
      expect(c.teacher, isNull);
      expect(_parse('Maths, We, 2, ,').classes.single.room, isNull);
    });

    test('a double period spans both blocks', () {
      final ImportedClass c = _parse('ECE2104L, Mo, 1-2').classes.single;
      expect(c.startMinutes, 9 * 60 + 10);
      expect(c.endMinutes, 10 * 60 + 50);
    });

    test('the short last block imports at its real length', () {
      final ImportedClass c = _parse('ECE3311, Tu, 9').classes.single;
      expect(c.startMinutes, 15 * 60 + 50);
      expect(c.endMinutes, 16 * 60 + 30);
    });

    test('a clock range works where the periods do not match the grid', () {
      final ImportedClass c = _parse('Physics, Fr, 14:20-15:20').classes.single;
      expect(c.startMinutes, 14 * 60 + 20);
      expect(c.endMinutes, 15 * 60 + 20);
    });

    test('days are read long, short or two-letter, in any case', () {
      const String text = 'A, Mo, 1\nB, TUESDAY, 1\nC, wed, 1\nD, Th, 1';
      expect(
        _parse(text).classes.map((ImportedClass c) => c.weekday),
        <int>[1, 2, 3, 4],
      );
    });
  });

  group('what the paste can get wrong', () {
    test('a line that is missing a field says so', () {
      expect(_parse('ECE1102, Mo').problems.single.error,
          contains('at least a subject'));
    });

    test('an unrecognised day names the token', () {
      expect(_parse('ECE1102, Moon, 1').problems.single.error,
          contains('Moon'));
    });

    test('a block past the end of the day is refused', () {
      expect(_parse('ECE1102, Mo, 12').problems.single.error,
          contains('only has 9 blocks'));
    });

    test('a backwards range is refused, either way of writing it', () {
      expect(_parse('ECE1102, Mo, 4-2').problems, hasLength(1));
      expect(_parse('ECE1102, Mo, 15:20-14:20').problems.single.error,
          contains('before it starts'));
    });

    test('block numbers need a grid to count against', () {
      final TimetableImportResult result =
          TimetableImport.parse('ECE1102, Mo, 5', grid: DayGrid.none);
      expect(result.problems.single.error, contains('no blocks'));
    });

    test('a good line is kept even when its neighbour is broken', () {
      final TimetableImportResult result =
          _parse('ECE1102, Mo, 5\nbroken\nMaths, Tu, 1');
      expect(result.classes, hasLength(2));
      expect(result.problems, hasLength(1));
      expect(result.hasProblems, isTrue);
    });
  });

  group('two classes that would share an attendance key', () {
    test('the second is refused and points at the first', () {
      final TimetableImportResult result =
          _parse('ECE1102, Mo, 5\nECE1102, Mo, 5');
      expect(result.classes, hasLength(1));
      expect(result.problems.single.error, contains('line 1'));
    });

    test('the same slot for a different subject is fine', () {
      expect(_parse('A, Mo, 5\nB, Mo, 5').problems, isEmpty);
    });

    test('the same subject at a different time is fine', () {
      expect(_parse('A, Mo, 5\nA, Mo, 6').problems, isEmpty);
    });
  });

  group('reading the paste as a whole', () {
    test('blank lines and comments are skipped', () {
      final TimetableImportResult result =
          _parse('\n# my timetable\n\nA, Mo, 1\n');
      expect(result.classes, hasLength(1));
      expect(result.hasProblems, isFalse);
    });

    test('line numbers match the pasted text, not the parsed rows', () {
      // Reporting the third row as "line 3" when it is line 5 on screen makes
      // the error impossible to find.
      final TimetableImportResult result = _parse('A, Mo, 1\n\n\nnonsense');
      expect(result.problems.single.number, 4);
    });

    test('subjects are deduped by name, in the order they appear', () {
      final TimetableImportResult result =
          _parse('Physics, Mo, 1\nMaths, Tu, 1\n physics , We, 1');
      expect(result.subjectNames, <String>['Physics', 'Maths']);
    });

    test('rooms are collected once each for the saved list', () {
      final TimetableImportResult result =
          _parse('A, Mo, 1, B204\nB, Tu, 1, b204\nC, We, 1, LT-3\nD, Th, 1');
      expect(result.roomNames, <String>['B204', 'LT-3']);
    });

    test('an empty paste is empty rather than broken', () {
      final TimetableImportResult result = _parse('   \n\n');
      expect(result.isEmpty, isTrue);
      expect(result.hasProblems, isFalse);
    });
  });
}
