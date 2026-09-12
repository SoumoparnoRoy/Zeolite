import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/timetable_ocr.dart';
import 'package:zeolite/domain/vision_merge.dart';
import 'package:zeolite/domain/vision_read.dart';

/// A fifty-minute day from 8:30, so 510, 560, 610 and 660 are the only
/// boundaries a class on this sheet is allowed to have.
TimetableGrid _grid() => const TimetableGrid(
      axis: GridAxis.daysAsRows,
      days: <GridBand>[
        GridBand(label: 'Mo', start: 100, end: 200, weekday: 1),
        GridBand(label: 'Tu', start: 200, end: 300, weekday: 2),
      ],
      periods: <GridBand>[
        GridBand(label: '8:30-9:20', start: 220, end: 368),
        GridBand(label: '9:20-10:10', start: 368, end: 516),
        GridBand(label: '10:10-11:00', start: 516, end: 664),
      ],
    );

/// A line of text sitting in one cell of [_grid], `period` 0 being the first.
OcrLine _in(int weekday, int period, String text) {
  final double y = 100.0 + (weekday - 1) * 100 + 50;
  final double x = 220.0 + period * 148 + 74;
  return OcrLine(text, OcrBox(x - 30, y - 8, x + 30, y + 8));
}

VisionClass _byColumn(int first, int last, {String subject = 'AAA1001'}) =>
    VisionClass(
      subject: subject,
      weekday: 1,
      room: 'R101',
      first: first,
      last: last,
    );

OcrEntry _local(int from, int to) => OcrEntry(
      subject: 'BBB2002',
      weekday: 1,
      from: from,
      to: to,
    );

void main() {
  group('placing what the model returned', () {
    test('a class named by its period columns lands on the printed hours', () {
      final List<OcrEntry> placed =
          VisionMerge.placedOn(_grid(), <VisionClass>[_byColumn(1, 1)]);

      expect(placed.single.from, 510);
      expect(placed.single.to, 560);
      expect(placed.single.room, 'R101');
    });

    test('a class across two columns keeps both of them', () {
      final List<OcrEntry> placed =
          VisionMerge.placedOn(_grid(), <VisionClass>[_byColumn(1, 2)]);

      expect(placed.single.from, 510);
      expect(placed.single.to, 610);
    });

    // The other reply shape, which cannot place itself.
    test('a class given as clocks is snapped to the printed hours', () {
      final List<OcrEntry> placed = VisionMerge.placedOn(
        _grid(),
        const <VisionClass>[
          VisionClass(subject: 'AAA1001', weekday: 1, from: 520, to: 575),
        ],
      );

      expect(placed.single.from, 510);
      expect(placed.single.to, 560);
    });

    // A column number this sheet does not print means the model was counting
    // something other than the grid, so the class says nothing about when.
    test('a column the sheet does not have is dropped, not clamped', () {
      expect(
        VisionMerge.placedOn(_grid(), <VisionClass>[_byColumn(9, 9)]),
        isEmpty,
      );
    });
  });

  group('cross-checking against what the device read', () {
    test('a subject read in that very cell is kept', () {
      final List<OcrEntry> kept = VisionMerge.corroboratedBy(
        _grid(),
        <OcrLine>[_in(1, 0, 'AAA1001'), _in(1, 0, 'R101')],
        <OcrEntry>[
          OcrEntry(subject: 'AAA1001', weekday: 1, from: 510, to: 560),
        ],
      );

      expect(kept, hasLength(1));
    });

    // Measured: on a sheet of 21 classes the model returned 38, filling empty
    // periods with codes copied from elsewhere on the same page.
    test('a real code put in an empty cell is dropped', () {
      final List<OcrEntry> kept = VisionMerge.corroboratedBy(
        _grid(),
        <OcrLine>[_in(1, 0, 'AAA1001')],
        <OcrEntry>[
          OcrEntry(subject: 'AAA1001', weekday: 1, from: 560, to: 610),
        ],
      );

      expect(kept, isEmpty);
    });

    test('the same hour on another day does not corroborate it', () {
      final List<OcrEntry> kept = VisionMerge.corroboratedBy(
        _grid(),
        <OcrLine>[_in(1, 0, 'AAA1001')],
        <OcrEntry>[
          OcrEntry(subject: 'AAA1001', weekday: 2, from: 510, to: 560),
        ],
      );

      expect(kept, isEmpty);
    });

    // A substring check let this through, because it is one.
    test('a mis-read course code does not pass as corroborated', () {
      final List<OcrEntry> kept = VisionMerge.corroboratedBy(
        _grid(),
        <OcrLine>[_in(1, 0, 'AAA1001')],
        <OcrEntry>[OcrEntry(subject: 'AA1001', weekday: 1, from: 510, to: 560)],
      );

      expect(kept, isEmpty);
    });

    test('spacing and punctuation do not decide it', () {
      final List<OcrEntry> kept = VisionMerge.corroboratedBy(
        _grid(),
        <OcrLine>[_in(1, 0, 'ABC : DEF : B1')],
        <OcrEntry>[
          OcrEntry(subject: 'ABC:DEF:B1', weekday: 1, from: 510, to: 560),
        ],
      );

      expect(kept, hasLength(1));
    });

    // A lab covers two columns, so either of them holding the code is enough.
    test('a class spanning two periods is corroborated by either', () {
      final List<OcrEntry> kept = VisionMerge.corroboratedBy(
        _grid(),
        <OcrLine>[_in(1, 1, 'AAA1001')],
        <OcrEntry>[
          OcrEntry(subject: 'AAA1001', weekday: 1, from: 510, to: 610),
        ],
      );

      expect(kept, hasLength(1));
    });
  });

  group('folding it into the local read', () {
    test('a class in a free hour is added', () {
      final List<OcrEntry> merged = VisionMerge.filling(
        <OcrEntry>[_local(510, 560)],
        <OcrEntry>[
          OcrEntry(subject: 'AAA1001', weekday: 1, from: 610, to: 660),
        ],
      );

      expect(merged, hasLength(2));
      expect(merged.last.subject, 'AAA1001');
    });

    // The whole point of the split: the parser owns the grid.
    test('the local class keeps an hour both of them found', () {
      final List<OcrEntry> merged = VisionMerge.filling(
        <OcrEntry>[_local(510, 560)],
        <OcrEntry>[
          OcrEntry(subject: 'AAA1001', weekday: 1, from: 510, to: 560),
        ],
      );

      expect(merged.single.subject, 'BBB2002');
    });

    test('the same hour on another day is not a clash', () {
      final List<OcrEntry> merged = VisionMerge.filling(
        <OcrEntry>[_local(510, 560)],
        <OcrEntry>[
          OcrEntry(subject: 'AAA1001', weekday: 2, from: 510, to: 560),
        ],
      );

      expect(merged, hasLength(2));
    });
  });
}
