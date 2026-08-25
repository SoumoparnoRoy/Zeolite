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
      {this.percent,
      this.pipe = false,
      this.unread = false,
      this.merged = false});

  final List<String> nameLines;
  final int total;
  final int marked;
  final int attended;
  final String? percent;

  /// Whether the cell rule came back glued to the digits.
  final bool pipe;

  /// Whether the number cells came back at all. A row of lone zeroes is the
  /// case where they do not.
  final bool unread;

  /// Whether the term total came back glued to the end of the name, as one
  /// line reaching from the name column into the total's.
  final bool merged;
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
      final bool last = n == row.nameLines.length - 1;
      if (row.merged && last) {
        // One line from the name column to the far side of the total's, which
        // is what the recogniser hands back when it runs the two together.
        lines.add(
          OcrLine(
            '${row.nameLines[n]} |${row.total}',
            OcrBox(_name - 150, centre - 11, _total + 20, centre + 11),
          ),
        );
        continue;
      }
      lines.add(_at(row.nameLines[n], _name, centre + offset, w: 300));
    }
    final String rule = row.pipe ? '|' : '';
    if (!row.unread) {
      if (!row.merged) {
        lines.add(_at('$rule${row.total}', _total, centre, w: 40));
      }
      lines
        ..add(_at('${row.marked}', _marked, centre, w: 40))
        ..add(_at('$rule${row.attended}', _attended, centre, w: 40));
    }
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

/// What a second, magnified read of the number columns hands back: the digits
/// alone, with none of the names or percentages beside them.
///
/// [missing] names the columns that read still did not return, per row index —
/// 0 total, 1 marked, 2 attended.
List<OcrLine> _cells(
  List<_Row> rows, {
  Map<int, Set<int>> missing = const <int, Set<int>>{},
}) {
  final List<OcrLine> lines = <OcrLine>[];
  for (int i = 0; i < rows.length; i++) {
    final _Row row = rows[i];
    final double centre = _firstRow + i * _rowHeight;
    final Set<int> gone = missing[i] ?? const <int>{};
    // A total the name ran into is one this read did not get either: it sits
    // on the name's line, outside the band this read was given.
    if (!gone.contains(0) && !row.merged) {
      lines.add(_at('${row.total}', _total, centre, w: 40));
    }
    if (!gone.contains(1)) {
      lines.add(_at('${row.marked}', _marked, centre, w: 40));
    }
    if (!gone.contains(2)) {
      lines.add(_at('${row.attended}', _attended, centre, w: 40));
    }
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

    test('names the number columns for a second look at them', () {
      final OcrBox band = AttendanceTotalsOcr.numberColumns(_sheet(_threeRows))!;
      // Wide enough for the three number headers, and short of the percentage.
      expect(band.left, lessThan(_total));
      expect(band.right, greaterThan(_attended));
      expect(band.right, lessThan(_percent));
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

    test('a row of zeroes the recogniser skipped is still its own course', () {
      final AttendanceTotals totals = AttendanceTotalsOcr.read(_sheet(<_Row>[
        ..._threeRows,
        const _Row(<String>['Imaging Lab_Odd_2026-27'], 0, 0, 0,
            percent: '-', unread: true),
        const _Row(<String>['Thermodynamics_Odd_2026-27'], 21, 21, 14,
            percent: '66.67%'),
      ]))!;
      expect(totals.rows, hasLength(5));

      final TotalsRow blank = totals.rows[3];
      expect(blank.subject, 'Imaging Lab');
      expect(blank.expectedTotal, 0);
      expect(blank.held, 0);
      expect(blank.attended, 0);
      expect(blank.isTrustworthy, isTrue);

      // The row below is the one that used to be lost with it.
      expect(totals.rows[4].subject, 'Thermodynamics');
      expect(totals.rows[4].attended, 14);
    });

    test('a cell read on its own lands in its own column', () {
      // The magnified read gives back digits with nothing to anchor them to
      // but their position, so the column has to be worked out table-wide.
      const List<_Row> sheet = <_Row>[
        ..._threeRows,
        _Row(<String>['Imaging Lab_Odd_2026-27'], 7, 7, 6,
            percent: '85.71%', unread: true),
      ];
      final AttendanceTotals totals =
          AttendanceTotalsOcr.read(_sheet(sheet), cells: _cells(sheet))!;
      final TotalsRow row = totals.rows.last;
      expect(row.subject, 'Imaging Lab');
      expect(row.expectedTotal, 7);
      expect(row.held, 7);
      expect(row.attended, 6);
    });

    test('a missing attended is taken back off the printed percentage', () {
      const List<_Row> sheet = <_Row>[
        ..._threeRows,
        _Row(<String>['Imaging Lab_Odd_2026-27'], 7, 7, 7,
            percent: '100.00%', unread: true),
      ];
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(sheet),
        cells: _cells(sheet, missing: <int, Set<int>>{3: <int>{2}}),
      )!;
      final TotalsRow row = totals.rows.last;
      expect(row.held, 7);
      expect(row.attended, 7);
      expect(row.isTrustworthy, isTrue);
    });

    test('a missing held is taken back off the printed percentage', () {
      const List<_Row> sheet = <_Row>[
        ..._threeRows,
        _Row(<String>['Imaging Lab_Odd_2026-27'], 7, 7, 6,
            percent: '85.71%', unread: true),
      ];
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(sheet),
        cells: _cells(sheet, missing: <int, Set<int>>{3: <int>{1}}),
      )!;
      final TotalsRow row = totals.rows.last;
      expect(row.held, 7);
      expect(row.attended, 6);
    });

    test('a percentage that cannot be squared with the digit is refused', () {
      // 6 of 13 is 46.15% and 6 of 14 is 42.86%: no whole number of sessions
      // gives the 45% printed, so nothing is derived from it.
      const List<_Row> sheet = <_Row>[
        ..._threeRows,
        _Row(<String>['Imaging Lab_Odd_2026-27'], 7, 7, 6,
            percent: '45.00%', unread: true),
      ];
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(sheet),
        cells: _cells(sheet, missing: <int, Set<int>>{3: <int>{1}}),
      )!;

      expect(totals.rows, hasLength(4));
      expect(totals.rows.last.subject, 'Imaging Lab');
      expect(totals.rows.last.numbersUnread, isTrue);
      expect(totals.rows.last.held, 0);
      expect(totals.rows.last.attended, 0);
    });

    test('the footer pins the one term total that went unread', () {
      const List<_Row> sheet = <_Row>[
        ..._threeRows,
        _Row(<String>['Imaging Lab_Odd_2026-27'], 6, 6, 4,
            percent: '66.67%', unread: true),
      ];
      // 18 + 5 + 20 read, so the page's 49 leaves exactly 6 for the last row.
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(sheet, footer: 'Total Session:49'),
        cells: _cells(sheet, missing: <int, Set<int>>{3: <int>{0}}),
      )!;
      expect(totals.rows.last.expectedTotal, 6);
      expect(totals.addsUp, isTrue);
    });

    test('two unread term totals are left alone, not split', () {
      const List<_Row> sheet = <_Row>[
        ..._threeRows,
        _Row(<String>['Imaging Lab_Odd_2026-27'], 6, 6, 4,
            percent: '66.67%', unread: true),
        _Row(<String>['Thermodynamics_Odd_2026-27'], 6, 6, 4,
            percent: '66.67%', unread: true),
      ];
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(sheet, footer: 'Total Session:55'),
        cells: _cells(sheet,
            missing: <int, Set<int>>{3: <int>{0}, 4: <int>{0}}),
      )!;
      expect(totals.rows[3].expectedTotal, isNull);
      expect(totals.rows[4].expectedTotal, isNull);
    });

    test('a dash beside a digit is refused rather than read as zero', () {
      final List<OcrLine> lines = _sheet(_threeRows)
        ..add(_at('Imaging Lab_Odd_2026-27', _name, 320, w: 300))
        ..add(_at('7', _total, 320, w: 40))
        ..add(_at('-', _percent, 320, w: 40));
      final AttendanceTotals totals = AttendanceTotalsOcr.read(lines)!;

      expect(totals.rows, hasLength(4));
      final TotalsRow refused = totals.rows.last;
      expect(refused.subject, 'Imaging Lab');
      expect(refused.numbersUnread, isTrue);
      expect(refused.isTrustworthy, isFalse);
      expect(totals.suspect, contains(refused));
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
      expect(totals.rows.last.subject, 'Control Systems');
      expect(totals.rows.last.isTrustworthy, isTrue);
    });

    test('a total percentage line stays out of the last course name', () {
      final List<OcrLine> lines = _sheet(_threeRows,
          footer: 'Total Session:43', footerAttended: 'Total Attended Session: 34')
        ..add(_at('Total Percentage: 79.06%', 500, 400, w: 400));
      final AttendanceTotals totals = AttendanceTotalsOcr.read(lines)!;
      expect(totals.rows.last.subject, 'Control Systems');
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

  group('a cell glued onto the name beside it', () {
    test('is taken back off the name and counted as its own column', () {
      final List<_Row> rows = <_Row>[
        const _Row(<String>['Signal Theory_Odd_2026-27'], 18, 16, 14,
            percent: '87.50%', merged: true),
        ..._threeRows.sublist(1),
      ];
      final AttendanceTotals page = AttendanceTotalsOcr.read(_sheet(rows))!;

      expect(page.rows, hasLength(3));
      expect(page.rows.first.subject, 'Signal Theory');
      expect(page.rows.first.expectedTotal, 18);
      expect(page.rows.first.held, 16);
      expect(page.rows.first.attended, 14);
      expect(page.rows.first.isTrustworthy, isTrue);
    });

    test('reaches the caller that read the number columns separately', () {
      final List<_Row> rows = <_Row>[
        const _Row(<String>['Signal Theory_Odd_2026-27'], 18, 16, 14,
            percent: '87.50%', merged: true),
        ..._threeRows.sublist(1),
      ];
      // The sharper read missed it too, so the split is the only way back.
      final AttendanceTotals page = AttendanceTotalsOcr.read(
        _sheet(rows),
        cells: _cells(rows, missing: <int, Set<int>>{
          0: <int>{0}
        }),
      )!;

      expect(page.rows.first.expectedTotal, 18);
      expect(page.rows.first.subject, 'Signal Theory');
    });

    test('leaves the year of a term stamp where it is', () {
      // `_Odd_2026-27` ends in digits with nothing between them and the name,
      // which is what separates a stamp from a cell.
      final AttendanceTotals page =
          AttendanceTotalsOcr.read(_sheet(_threeRows))!;

      expect(page.rows.first.subject, 'Signal Theory');
      expect(page.rows.first.expectedTotal, 18);
    });

    test('leaves a name whose line stops short of the number columns', () {
      final AttendanceTotals page = AttendanceTotalsOcr.read(
        _sheet(const <_Row>[
          _Row(<String>['Workshop Practice 2_Odd_2026-27'], 18, 16, 14,
              percent: '87.50%'),
          _Row(<String>['Control Systems_Odd_2026-27'], 20, 19, 16,
              percent: '84.21%'),
        ]),
      )!;

      expect(page.rows.first.subject, 'Workshop Practice 2');
      expect(page.rows.first.expectedTotal, 18);
    });

    test('two merges stop crowding out the one total that is really gone', () {
      // The page's total can only pin a term total when it is the last one
      // unknown, so every merge left standing costs the unread cell as well.
      const List<_Row> rows = <_Row>[
        _Row(<String>['Signal Theory_Odd_2026-27'], 21, 21, 21,
            percent: '100.00%', merged: true),
        _Row(<String>['Signal Theory Lab_Odd_2026-27'], 7, 7, 7,
            percent: '100.00%', merged: true),
        _Row(<String>['Control Systems_Odd_2026-27'], 5, 5, 4,
            percent: '80.00%'),
        _Row(<String>['Thermodynamics_Odd_2026-27'], 21, 21, 18,
            percent: '85.71%'),
      ];
      final AttendanceTotals page = AttendanceTotalsOcr.read(
        _sheet(rows, footer: 'Total Session:54'),
        // The lone digit of the third row's total went unread on both passes.
        cells: _cells(rows, missing: <int, Set<int>>{
          2: <int>{0}
        }),
      )!;

      expect(page.rows.map((TotalsRow r) => r.expectedTotal),
          <int>[21, 7, 5, 21]);
      expect(page.totalSum, 54);
      expect(page.addsUp, isTrue);
      expect(page.suspect, isEmpty);
    });

    test('the footer keeps its own number', () {
      final AttendanceTotals page = AttendanceTotalsOcr.read(
        _sheet(_threeRows,
            footer: 'Total Session:43',
            footerAttended: 'Total Attended Session: 34'),
      )!;

      expect(page.rows, hasLength(3));
      expect(page.printedTotal, 43);
      expect(page.printedAttended, 34);
    });
  });

  group('a row whose numbers cannot be read', () {
    test('counts nothing towards the page, so the footer still disagrees', () {
      final List<OcrLine> lines = _sheet(
        _threeRows,
        footer: 'Total Session:50',
        footerAttended: 'Total Attended Session: 40',
      )
        ..add(_at('Imaging Lab_Odd_2026-27', _name, 320, w: 300))
        ..add(_at('7', _total, 320, w: 40))
        ..add(_at('-', _percent, 320, w: 40));
      final AttendanceTotals totals = AttendanceTotalsOcr.read(lines)!;

      expect(totals.rows, hasLength(4));
      expect(totals.attendedSum, 34);
      expect(totals.addsUp, isFalse);
    });

    test('stops the footer pinning a term total it no longer covers', () {
      // 45 is all three rows, so what is left over after the two readable
      // ones is not the third row's alone.
      const List<_Row> sheet = <_Row>[
        _Row(<String>['Signal Theory_Odd_2026-27'], 18, 16, 14,
            percent: '87.50%'),
        _Row(<String>['Control Systems_Odd_2026-27'], 20, 19, 16,
            percent: '84.21%'),
      ];
      final List<OcrLine> lines = _sheet(sheet, footer: 'Total Session:45')
        ..add(_at('Imaging Lab_Odd_2026-27', _name, 260, w: 300))
        ..add(_at('7', _total, 260, w: 40))
        ..add(_at('-', _percent, 260, w: 40));
      final AttendanceTotals totals = AttendanceTotalsOcr.read(lines)!;

      final TotalsRow unreadable =
          totals.rows.firstWhere((TotalsRow r) => r.numbersUnread);
      expect(unreadable.expectedTotal, isNull);
      for (final TotalsRow r in totals.rows) {
        expect(r.numbersUnread || r.expectedTotal != null, isTrue);
      }
    });

    test('a course with no sessions yet is not refused', () {
      // A dash and no digits at all is a term that has not started, which is
      // readable — it must not be swept up by the refusal above.
      final AttendanceTotals totals = AttendanceTotalsOcr.read(
        _sheet(const <_Row>[
          _Row(<String>['Signal Theory_Odd_2026-27'], 18, 16, 14,
              percent: '87.50%'),
          _Row(<String>['Imaging Lab_Odd_2026-27'], 0, 0, 0,
              percent: '-', unread: true),
        ]),
      )!;

      final TotalsRow blank = totals.rows.last;
      expect(blank.subject, 'Imaging Lab');
      expect(blank.numbersUnread, isFalse);
      expect(blank.isTrustworthy, isTrue);
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

    test('a stamp followed by digits alone is one course, not two', () {
      const String name =
          'Signal Theory_Odd_2026-27 |18 Control Systems_Odd_2026-27';
      expect(AttendanceTotalsOcr.cleanName(name), isNot('Signal Theory'));

      final AttendanceTotals page = AttendanceTotalsOcr.read(
        _sheet(<_Row>[
          const _Row(<String>['Signal Theory_Odd_2026-27'], 18, 16, 14,
              percent: '87.50%', merged: true),
          ..._threeRows.sublist(1),
        ]),
      )!;
      expect(page.rows.first.namesTwoCourses, isFalse);
      expect(page.suspect, isEmpty);
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
