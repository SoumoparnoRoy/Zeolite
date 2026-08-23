import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/attendance_totals_ocr.dart';
import 'package:zeolite/domain/timetable_ocr.dart';

/// Column centres of the sheet these tests draw, in image pixels.
const double _name = 200;
const double _total = 520;
const double _marked = 640;
const double _attended = 760;
const double _percent = 890;

const double _rowHeight = 60;
const double _firstRow = 140;

OcrLine _at(String text, double centreX, double centreY, {double w = 90}) {
  return OcrLine(
    text,
    OcrBox(centreX - w / 2, centreY - 11, centreX + w / 2, centreY + 11),
  );
}

/// A row of the sheet: the name may be several lines, as a long course title
/// is on a screenshot narrow enough to wrap it.
class _Row {
  const _Row(this.nameLines, this.total, this.marked, this.attended,
      {this.percent, this.pipe = false});

  final List<String> nameLines;
  final int total;
  final int marked;
  final int attended;
  final String? percent;

  /// Whether the cell rule came back glued to the digits.
  final bool pipe;
}

List<OcrLine> _sheet(List<_Row> rows, {String? footer, String? footerAttended}) {
  final List<OcrLine> lines = <OcrLine>[
    // The header wraps: "Total Sessions" is drawn as two lines, and the second
    // one sits lower than "Percentage" beside it.
    _at('Course Name', _name, 60),
    _at('Total', _total, 52),
    _at('Sessions', _total, 76),
    _at('Marked', _marked, 52),
    _at('Sessions', _marked, 76),
    _at('Attended', _attended, 52),
    _at('Sessions', _attended, 76),
    _at('Percentage', _percent, 60),
  ];

  for (int i = 0; i < rows.length; i++) {
    final _Row row = rows[i];
    final double centre = _firstRow + i * _rowHeight;
    for (int n = 0; n < row.nameLines.length; n++) {
      // Wrapped name lines straddle the centre the numbers sit on.
      final double offset =
          (n - (row.nameLines.length - 1) / 2) * 22;
      lines.add(_at(row.nameLines[n], _name, centre + offset, w: 300));
    }
    final String rule = row.pipe ? '|' : '';
    lines
      ..add(_at('$rule${row.total}', _total, centre, w: 40))
      ..add(_at('${row.marked}', _marked, centre, w: 40))
      ..add(_at('$rule${row.attended}', _attended, centre, w: 40));
    if (row.percent != null) {
      lines.add(_at(row.percent!, _percent, centre, w: 80));
    }
  }

  final double below = _firstRow + rows.length * _rowHeight + 40;
  if (footer != null) lines.add(_at(footer, 500, below, w: 400));
  if (footerAttended != null) {
    lines.add(_at(footerAttended, 500, below + 40, w: 400));
  }
  return lines;
}

/// The same row as a bordered table gives it: the cell rule reads as a pipe.
_Row _bordered(_Row row) => _Row(
      row.nameLines,
      row.total,
      row.marked,
      row.attended,
      percent: row.percent == null ? null : '|${row.percent}',
      pipe: true,
    );

const List<_Row> _threeRows = <_Row>[
  _Row(<String>['Signal Theory_Odd_2026-27'], 18, 16, 14, percent: '87.50%'),
  _Row(<String>['Signal Theory Lab_Odd_2026-27'], 5, 5, 4, percent: '80.00%'),
  _Row(<String>['Control Systems_Odd_2026-27'], 20, 19, 16, percent: '84.21%'),
];

void main() {
  group('spotting the page', () {
    test('takes a table that names its columns', () {
      expect(AttendanceTotalsOcr.looksLikeTotals(_sheet(_threeRows)), isTrue);
    });

    test('leaves a timetable alone', () {
      final List<OcrLine> timetable = <OcrLine>[
        _at('MON', 100, 40),
        _at('TUE', 200, 40),
        _at('9:10-10:00', 300, 40),
        _at('AAA1001', 100, 100),
      ];
      expect(AttendanceTotalsOcr.looksLikeTotals(timetable), isFalse);
      expect(AttendanceTotalsOcr.read(timetable), isNull);
    });
  });

  group('reading the rows', () {
    test('maps the three columns onto the three fields', () {
      final AttendanceTotals totals =
          AttendanceTotalsOcr.read(_sheet(_threeRows))!;

      expect(totals.rows, hasLength(3));
      final TotalsRow first = totals.rows.first;
      expect(first.subject, 'Signal Theory');
      expect(first.expectedTotal, 18);
      expect(first.held, 16);
      expect(first.attended, 14);
      expect(first.printedPercent, 87.5);
    });

    test('the header does not leak into the first course name', () {
      final AttendanceTotals totals =
          AttendanceTotalsOcr.read(_sheet(_threeRows))!;
      expect(totals.rows.first.subject, isNot(contains('Sessions')));
    });

    test('joins a course name that wrapped onto two lines', () {
      final AttendanceTotals totals = AttendanceTotalsOcr.read(_sheet(<_Row>[
        const _Row(
          <String>['Microprocessors and', 'Applications_Odd_2026-27'],
          19,
          19,
          13,
          percent: '68.42%',
        ),
        ..._threeRows,
      ]))!;
      expect(totals.rows.first.subject, 'Microprocessors and Applications');
    });

    test('a term stamp broken mid-way is not read as a number cell', () {
      // The stamp wraps, leaving a bare "27" in the name column. Taking the
      // three numbers from the left would make that the term total.
      final AttendanceTotals totals = AttendanceTotalsOcr.read(_sheet(<_Row>[
        const _Row(
          <String>['Embedded Systems_Odd_2026-', '27'],
          18,
          18,
          15,
          percent: '83.33%',
        ),
        ..._threeRows,
      ]))!;
      final TotalsRow row = totals.rows.first;
      expect(row.subject, 'Embedded Systems');
      expect(row.expectedTotal, 18);
      expect(row.held, 18);
      expect(row.attended, 15);
    });

    test('a course with no sessions yet reads as zeroes, not as nothing', () {
      final AttendanceTotals totals = AttendanceTotalsOcr.read(_sheet(<_Row>[
        ..._threeRows,
        // The portal prints a dash where the percentage would be.
        const _Row(<String>['Imaging Lab_Odd_2026-27'], 0, 0, 0, percent: '-'),
      ]))!;
      final TotalsRow last = totals.rows.last;
      expect(last.subject, 'Imaging Lab');
      expect(last.expectedTotal, 0);
      expect(last.printedPercent, isNull);
      expect(last.isTrustworthy, isTrue);
    });
  });

  group('checking its own working', () {
    test('a row whose printed percentage disagrees is not trusted', () {
      // 14 of 16 is 87.5%, so a 6 misread as 8 shows up as a contradiction.
      const TotalsRow misread = TotalsRow(
        subject: 'Signal Theory',
        expectedTotal: 18,
        held: 18,
        attended: 14,
        printedPercent: 87.5,
      );
      expect(misread.percentAgrees, isFalse);
      expect(misread.isTrustworthy, isFalse);
    });

    test('rounding does not count as disagreement', () {
      const TotalsRow row = TotalsRow(
        subject: 'Control Systems',
        expectedTotal: 20,
        held: 19,
        attended: 16,
        printedPercent: 84.21,
      );
      expect(row.percentAgrees, isTrue);
    });

    test('a row that attends more than it held is not trusted', () {
      const TotalsRow row = TotalsRow(
        subject: 'Control Systems',
        expectedTotal: 20,
        held: 4,
        attended: 9,
      );
      expect(row.isOrdered, isFalse);
    });

    test('the footer totals are read and checked against the rows', () {
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(
          _threeRows,
          footer: 'Total Session:43',
          footerAttended: 'Total Attended Session: 34',
        ),
      )!;

      expect(totals.printedTotal, 43);
      expect(totals.printedAttended, 34);
      expect(totals.totalSum, 43);
      expect(totals.attendedSum, 34);
      expect(totals.addsUp, isTrue);
    });

    test('a footer that disagrees with the rows says so', () {
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(_threeRows, footer: 'Total Session:61'),
      )!;
      expect(totals.printedTotal, 61);
      expect(totals.addsUp, isFalse);
    });

    test('a footer smaller than the rows is treated as unread', () {
      // The page's own total cannot be under the sum of its rows, so a "1"
      // where 43 belongs is a lost digit, not a disagreement.
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(_threeRows, footer: 'Total Session:1'),
      )!;
      expect(totals.printedTotal, isNull);
      expect(totals.addsUp, isTrue);
    });

    test('the footer lines do not become a course of their own', () {
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(
          _threeRows,
          footer: 'Total Session:43',
          footerAttended: 'Total Attended Session: 34',
        ),
      )!;
      expect(totals.rows, hasLength(3));
    });
  });

  group('a table drawn with borders', () {
    test('reads a number the cell rule glued a pipe onto', () {
      // Every second cell on a bordered page comes back like this, and a row
      // short of one number is dropped whole.
      final AttendanceTotals totals = AttendanceTotalsOcr.read(_sheet(<_Row>[
        const _Row(<String>['Signal Theory'], 21, 19, 15, percent: '78.95%'),
        ..._threeRows,
      ].map(_bordered).toList()))!;

      expect(totals.rows, hasLength(4));
      final TotalsRow first = totals.rows.first;
      expect(first.expectedTotal, 21);
      expect(first.held, 19);
      expect(first.attended, 15);
      expect(first.printedPercent, 78.95);
    });
  });

  group('two courses read as one', () {
    test('a stamp left in the middle of the name says the row is merged', () {
      // Happens when a row's numbers go unread: its name falls into the band
      // below and the two names run together.
      final AttendanceTotals totals = AttendanceTotalsOcr.read(_sheet(<_Row>[
        const _Row(
          <String>['Imaging Lab_Odd_2026-27 Operating Systems'],
          18,
          18,
          12,
          percent: '66.67%',
        ),
        ..._threeRows,
      ]))!;

      final TotalsRow row = totals.rows.first;
      expect(row.namesTwoCourses, isTrue);
      expect(row.isTrustworthy, isFalse);
    });

    test('a stamp at the end is just a stamp', () {
      final AttendanceTotals totals =
          AttendanceTotalsOcr.read(_sheet(_threeRows))!;
      expect(
        totals.rows.every((TotalsRow r) => !r.namesTwoCourses),
        isTrue,
      );
    });
  });

  group('the course name', () {
    test('loses the term stamp and keeps the course', () {
      expect(
        AttendanceTotalsOcr.cleanName('Signal Theory_Odd_2026-27'),
        'Signal Theory',
      );
      expect(
        AttendanceTotalsOcr.cleanName('Control Systems Lab_Even_2025-26'),
        'Control Systems Lab',
      );
      expect(
        AttendanceTotalsOcr.cleanName('Embedded Systems_Odd_2026- 27'),
        'Embedded Systems',
      );
    });

    test('drops punctuation the recogniser left on the end', () {
      expect(
        AttendanceTotalsOcr.cleanName('Signal Theory Lab,'),
        'Signal Theory Lab',
      );
    });

    test('leaves a name that carries no stamp', () {
      expect(
        AttendanceTotalsOcr.cleanName('Signal Theory'),
        'Signal Theory',
      );
    });

    test('survives the recogniser reading the O of Odd as a zero', () {
      expect(
        AttendanceTotalsOcr.cleanName('Signal Theory_0dd_2026-27'),
        'Signal Theory',
      );
      expect(
        AttendanceTotalsOcr.cleanName('3D Printing and Prototyping _0dd_2026-27'),
        '3D Printing and Prototyping',
      );
    });

    test('never strips a name down to nothing', () {
      expect(AttendanceTotalsOcr.cleanName('_Odd_2026-27'), '_Odd_2026-27');
    });
  });
}
