import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/domain/grid_lines.dart';
import 'package:zeolite/domain/timetable_ocr.dart';

import 'timetable_ocr_merged_lines_fixture.dart';

/// What both invented sheets print, in the order the parser hands it back.
const List<String> _printed = <String>[
  'CS201, Mo, 09:00-10:00, LT-101, EH',
  'MA203, Mo, 10:00-11:00, LT-102, KO',
  'CS201L, Mo, 13:00-15:00, LAB-11, EH',
  'CS204, Tu, 10:00-11:00, LT-101, MV',
  'CS206, Tu, 11:00-12:00, LT-102, JR',
  'HS101, Tu, 14:00-15:00, LT-103, NB',
  'MA203, We, 09:00-10:00, LT-102, KO',
  'CS201, We, 11:00-12:00, LT-101, EH',
  'CS204L, We, 13:00-15:00, LAB-12, MV',
  'CS206, Th, 09:00-10:00, LT-102, JR',
  'CS204, Th, 10:00-11:00, LT-101, MV',
];

List<String> _read(List<OcrLine> lines, TableLattice rules) =>
    TimetableOcr.joinedRuns(
      TimetableOcr.bestOf(<List<OcrLine>>[lines], lattice: rules).entries,
    ).map((OcrEntry e) => e.toLine()).toList();

void main() {
  group('a line the recogniser ran across a drawn rule', () {
    // Friday's two rooms came back as one line, and Friday's first class lost
    // its room and teacher to the class beside it.
    test('gives each class on the sheet its own room and teacher', () {
      expect(_read(fridayLines, fridayRules), <String>[
        ..._printed,
        'CS201, Fr, 09:00-10:00, LT-101, EH',
        'HS101, Fr, 10:00-11:00, LT-103, NB',
        'CS206, Fr, 11:00-12:00, LT-102, JR',
        'MA203, Fr, 13:00-14:00, LT-102, KO',
      ]);
    });

    // The tighter sheet merges far more, a lab's own code and four rooms in a
    // row among it, and one word holding the divider as a bar.
    test('holds on a sheet where most of the rooms merged', () {
      expect(_read(tightLines, tightRules), <String>[
        ..._printed,
        'HS101, Fr, 10:00-11:00, LT-103, NB',
        'CS206, Fr, 11:00-12:00, LT-102, JR',
        'MA203, Fr, 13:00-14:00, LT-102, KO',
        'CS201, Fr, 14:00-15:00, LT-101, EH',
      ]);
    });

    test('splits a word holding the divider where the rule runs', () {
      final OcrLine line = tightLines.singleWhere(
        (OcrLine l) => l.text == 'LT-101 EH LAB-12 MV|LAB-12 MV',
      );
      final List<OcrLine> cut = TimetableOcr.cutAtRules(
        <OcrLine>[line],
        tightRules,
      );

      expect(cut.map((OcrLine l) => l.text), <String>[
        'LT-101 EH',
        'LAB-12 MV',
        'LAB-12 MV',
      ]);
      expect(cut[1].box.right, 944);
      expect(cut[2].box.left, 944);
    });
  });

  group('a line left whole', () {
    OcrLine line() => fridayLines.singleWhere(
          (OcrLine l) => l.text == 'LT-101 EH LT-103 NB',
        );

    test('where the divider under it is not drawn, as across a lab', () {
      final TableLattice open = TableLattice(
        xs: fridayRules.xs,
        ys: fridayRules.ys,
        dividedRight: <List<bool>>[
          for (final List<bool> row in fridayRules.dividedRight)
            <bool>[for (final bool _ in row) false],
        ],
        dividedBelow: fridayRules.dividedBelow,
      );

      expect(TimetableOcr.cutAtRules(<OcrLine>[line()], open).single,
          same(line()));
    });

    test('outside the table, as a title across the columns is', () {
      final OcrLine title = fridayLines.singleWhere(
        (OcrLine l) => l.text == 'Sample College of Engineering',
      );

      expect(TimetableOcr.cutAtRules(<OcrLine>[title], fridayRules).single,
          same(title));
    });

    test('when it is one word, which has nowhere to break', () {
      const OcrLine wide = OcrLine(
        'CS201',
        OcrBox(230, 340, 310, 365),
        words: <OcrWord>[OcrWord('CS201', OcrBox(230, 340, 310, 365))],
      );

      expect(TimetableOcr.cutAtRules(<OcrLine>[wide], fridayRules).single,
          same(wide));
    });

    // Rules that hold no week are the page's, not the table's. A line cut at
    // those would be wrong on the sheets the label path exists for.
    test('when the lattice carries no week', () {
      final TableLattice stray = ruled(
        <int>[0, 400, 800],
        <int>[900, 1100],
      );

      final List<OcrLine> won = TimetableOcr.bestOf(
        <List<OcrLine>>[fridayLines],
        lattice: stray,
      ).lines;

      expect(won, contains(line()));
    });
  });
}
