import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/domain/timetable_ocr.dart';

OcrLine _at(String text, double x, double y, {double w = 60, double h = 20}) =>
    OcrLine(text, OcrBox(x - w / 2, y - h / 2, x + w / 2, y + h / 2));

/// Boxes shaped the way a recogniser hands back a timetable: weekday labels
/// down the left, period headers across the top, and in each cell a course code
/// with its room bottom-left and the teacher's initials bottom-right.
///
/// Built here rather than captured off a sheet, so each failure the device
/// turned up can be reproduced on its own and named.
class Sheet {
  Sheet({
    this.days = const <String>['Mo', 'Tu', 'We', 'Th', 'Fr'],
    this.headerTexts,
    this.periods = 9,
  });

  final List<String> days;

  /// Replaces the printed header for a period, for the misreads below.
  final Map<int, String>? headerTexts;
  final int periods;

  /// A uniform fifty-minute day, invented for these tests.
  static const List<String> times = <String>[
    '8:30-9:20',
    '9:20-10:10',
    '10:10-11:00',
    '11:00-11:50',
    '11:50-12:40',
    '12:40-13:30',
    '13:30-14:20',
    '14:20-15:10',
    '15:10-16:00',
  ];

  final List<OcrLine> lines = <OcrLine>[];

  double colX(int p) => 220 + 148.0 * p;
  double rowY(int d) => 110 + 105.0 * d;

  Sheet build() {
    for (int d = 0; d < days.length; d++) {
      lines.add(_at(days[d], 70, rowY(d), w: 30, h: 16));
    }
    for (int p = 0; p < periods; p++) {
      final String text = headerTexts?[p] ?? times[p];
      if (text.isEmpty) continue;
      lines.add(_at(text, colX(p), 45, w: 90, h: 8));
    }
    return this;
  }

  /// One class, optionally running [through] a later period as a lab does.
  Sheet put(
    int day,
    int period,
    String code, {
    int? through,
    String? room,
    String? teacher,
  }) {
    final double from = colX(period);
    final double to = colX(through ?? period);
    lines.add(_at(code, (from + to) / 2, rowY(day) - 10, w: 104, h: 18));
    if (room != null) {
      lines.add(_at(room, from - 64, rowY(day) + 35, w: 22, h: 7));
    }
    if (teacher != null) {
      lines.add(_at(teacher, to + 50, rowY(day) + 35, w: 18, h: 7));
    }
    return this;
  }

  /// A cell packing several classes in as `SUBJECT:TEACHER:ROOM`, which is how
  /// a sheet draws a period that is a choice between electives.
  Sheet stack(int day, int period, List<String> entries) {
    for (int i = 0; i < entries.length; i++) {
      lines.add(_at(entries[i], colX(period), rowY(day) - 20 + i * 14,
          w: 110, h: 10));
    }
    return this;
  }
}

/// Twenty-one classes over ten subjects, four of them running two periods.
List<OcrLine> _weekOfClasses({
  List<String> days = const <String>['Mo', 'Tu', 'We', 'Th', 'Fr'],
  Map<int, String>? headers,
}) {
  final Sheet s = Sheet(days: days, headerTexts: headers)..build();
  return (s
        ..put(0, 0, 'AAA1001', through: 1, room: 'R101', teacher: 'AB')
        ..put(0, 3, 'BBB2002', room: 'R102', teacher: 'CD')
        ..put(0, 4, 'CCC3003', room: 'R103', teacher: 'EF')
        ..put(0, 6, 'AAA1001L', through: 7, room: 'R104', teacher: 'AB')
        ..put(1, 0, 'CCC3003', room: 'R103', teacher: 'EF')
        ..put(1, 1, 'DDD4004', room: 'R105', teacher: 'GH')
        ..put(1, 2, 'BBB2002', room: 'R102', teacher: 'CD')
        ..put(1, 4, 'EEE5005', room: 'R106', teacher: 'IJ')
        ..put(1, 8, 'FFF6006', room: 'R107', teacher: 'KL')
        ..put(2, 0, 'GGG7007', room: 'R108', teacher: 'MN')
        ..put(2, 3, 'DDD4004', room: 'R105', teacher: 'GH')
        ..put(2, 4, 'EEE5005', room: 'R106', teacher: 'IJ')
        ..put(3, 0, 'DDD4004', room: 'R105', teacher: 'GH')
        ..put(3, 1, 'GGG7007', room: 'R108', teacher: 'MN')
        ..put(3, 2, 'EEE5005L', through: 3, room: 'R109', teacher: 'IJ')
        ..put(3, 4, 'BBB2002', room: 'R102', teacher: 'CD')
        ..put(3, 7, 'CCC3003', room: 'R103', teacher: 'EF')
        ..put(4, 0, 'DDD4004L', through: 1, room: 'R110', teacher: 'GH')
        ..put(4, 2, 'CCC3003', room: 'R103', teacher: 'EF')
        ..put(4, 3, 'EEE5005', room: 'R106', teacher: 'IJ')
        ..put(4, 7, 'GGG7007', room: 'R108', teacher: 'MN'))
      .lines;
}

/// Days across the top and times down the side, each class drawn as a type
/// badge, its name, its code and its room stacked in the cell.
List<OcrLine> _transposedSheet() {
  final List<OcrLine> lines = <OcrLine>[];
  const List<String> days = <String>[
    'MONDAY',
    'TUESDAY',
    'WEDNESDAY',
    'THURSDAY',
    'FRIDAY',
  ];
  for (int d = 0; d < days.length; d++) {
    lines.add(_at(days[d], 200 + d * 200.0, 30, w: 120, h: 14));
  }
  for (int p = 0; p < 6; p++) {
    lines.add(_at('${8 + p}:00AM', 60, 120 + p * 120.0, w: 60, h: 12));
  }
  void cell(int day, int period, String name, String code, String room) {
    final double x = 200 + day * 200.0;
    final double y = 120 + period * 120.0;
    lines
      ..add(_at('LECTURE', x, y - 34, w: 70, h: 10))
      ..add(_at(name, x, y - 14, w: 150, h: 12))
      ..add(_at(code, x, y + 6, w: 80, h: 11))
      ..add(_at(room, x, y + 26, w: 60, h: 11));
  }

  cell(0, 0, 'Operating Systems', 'PQR3011', 'LT201');
  cell(1, 1, 'Discrete Structures', 'PQR4022', 'LT202');
  cell(2, 2, 'Linear Algebra', 'STU5033', 'LT203');
  return lines;
}

void main() {
  group('naming a weekday', () {
    test('takes long, short and two-letter forms in any case', () {
      expect(TimetableGridReader.weekdayOf('Monday'), 1);
      expect(TimetableGridReader.weekdayOf('MON'), 1);
      expect(TimetableGridReader.weekdayOf('mo'), 1);
      expect(TimetableGridReader.weekdayOf('Th'), 4);
      expect(TimetableGridReader.weekdayOf('SAT'), 6);
    });

    // Inventing a row out of a course code would shift the whole grid.
    test('does not match a word that merely contains one', () {
      expect(TimetableGridReader.weekdayOf('SATCOM'), isNull);
      expect(TimetableGridReader.weekdayOf('MONT-2'), isNull);
      expect(TimetableGridReader.weekdayOf('R101'), isNull);
    });

    test('tolerates the punctuation a header carries', () {
      expect(TimetableGridReader.weekdayOf('MONDAY '), 1);
      expect(TimetableGridReader.weekdayOf('Fri.'), 5);
    });
  });

  group('spotting a time', () {
    test('finds one on its own and inside a range', () {
      expect(TimetableGridReader.namesATime('9:10'), isTrue);
      expect(TimetableGridReader.namesATime('12:40 - 1:35'), isTrue);
      expect(TimetableGridReader.namesATime('3.25'), isTrue);
    });

    test('is not fooled by a course code or a room', () {
      expect(TimetableGridReader.namesATime('AAA1001L'), isFalse);
      expect(TimetableGridReader.namesATime('R204A'), isFalse);
    });

    test('takes a header whose colon was lost', () {
      expect(TimetableGridReader.namesATime('910-1000'), isTrue);
      expect(TimetableGridReader.namesATime('1230-1320'), isTrue);
      expect(TimetableGridReader.namesATime('1500 - 1550'), isTrue);
    });

    test('takes a meridiem, which a transposed sheet prints', () {
      expect(TimetableGridReader.namesATime('8:00AM'), isTrue);
      expect(TimetableGridReader.namesATime('12:10PM'), isTrue);
    });

    // A colon-separated cell would hand `B3:51` to a substring match.
    test('a colon inside a cell is not a time', () {
      expect(TimetableGridReader.namesATime('MAL:HKR:B3:510TLI'), isFalse);
      expect(TimetableGridReader.namesATime('VLL:SRK:B2:40STL'), isFalse);
    });

    test('a bare number that is not a clock is refused', () {
      expect(TimetableGridReader.namesATime('2999'), isFalse);
      expect(TimetableGridReader.namesATime('3708'), isFalse);
    });
  });

  group('reading the axes', () {
    test('days down the side are rows', () {
      final TimetableGrid grid = TimetableGridReader.read(_weekOfClasses())!;
      expect(grid.axis, GridAxis.daysAsRows);
      expect(grid.days.map((GridBand b) => b.label),
          <String>['Mo', 'Tu', 'We', 'Th', 'Fr']);
      expect(grid.periods, hasLength(9));
    });

    test('days across the top are columns', () {
      final TimetableGrid grid = TimetableGridReader.read(_transposedSheet())!;
      expect(grid.axis, GridAxis.daysAsColumns);
      expect(grid.days, hasLength(5));
    });

    // Friday came back as a bare "F" on a real sheet, and used to be dropped
    // with a fifth of the week behind it.
    test('a weekday mangled to its initial is recovered from the pitch', () {
      final TimetableGrid grid = TimetableGridReader.read(
        _weekOfClasses(days: <String>['Mo', 'Tu', 'We', 'Th', 'F']),
      )!;
      expect(grid.days, hasLength(5));
      expect(grid.days.last.weekday, 5);
    });

    // Saturday and Sunday share an S, so a lone one names nothing — which is
    // what stops a legend entry under the table becoming a sixth day.
    test('an ambiguous initial is not adopted as a day', () {
      final List<OcrLine> lines = <OcrLine>[
        ..._weekOfClasses(),
        _at('S', 70, 110 + 105 * 5, w: 14, h: 14),
      ];
      expect(TimetableGridReader.read(lines)!.days, hasLength(5));
    });

    test('gives up on something that is not a timetable', () {
      expect(
        TimetableGridReader.read(<OcrLine>[
          _at('Shopping list', 10, 10),
          _at('Milk', 10, 40),
        ]),
        isNull,
      );
    });

    // A header whose dash is lost is not a time, so its column had no label and
    // its classes fell an hour out into a neighbour.
    test('a period whose header was lost is put back from the pitch', () {
      final TimetableGrid grid = TimetableGridReader.read(
        _weekOfClasses(headers: <int, String>{7: '14:20 15:10'}),
      )!;
      expect(grid.periods, hasLength(9));
    });
  });

  group('placing a cell', () {
    test('a class lands on the weekday and period it is drawn in', () {
      final TimetableGrid grid = TimetableGridReader.read(_weekOfClasses())!;
      final ({GridBand day, GridBand period})? cell =
          grid.cellFor(const OcrBox(180, 92, 260, 108));
      expect(cell?.day.label, 'Mo');
      expect(cell?.period.label, '8:30-9:20');
    });

    // The legend under a sheet is a column of names, none of them classes.
    test('something below the table belongs to no cell', () {
      final List<OcrLine> lines = <OcrLine>[
        ..._weekOfClasses(),
        _at('Dr Example', 120, 900, w: 160),
      ];
      final TimetableGrid grid = TimetableGridReader.read(lines)!;
      expect(grid.cellFor(const OcrBox(40, 890, 200, 910)), isNull);
    });
  });

  group('reading classes out of the cells', () {
    test('one line per class and no more', () {
      final List<OcrLine> lines = _weekOfClasses();
      final List<String> out =
          TimetableOcr.toLines(lines, TimetableGridReader.read(lines)!);
      expect(out, hasLength(21));
    });

    test('every line parses as the paste format expects', () {
      final List<OcrLine> lines = _weekOfClasses();
      for (final String line
          in TimetableOcr.toLines(lines, TimetableGridReader.read(lines)!)) {
        final List<String> f =
            line.split(',').map((String s) => s.trim()).toList();
        expect(f.length, greaterThanOrEqualTo(3));
        expect(TimetableGridReader.weekdayOf(f[1]), isNotNull);
        expect(f[2], matches(RegExp(r'^\d{2}:\d{2}-\d{2}:\d{2}$')));
      }
    });

    test('the room and the teacher come through', () {
      final List<OcrLine> lines = _weekOfClasses();
      final OcrEntry single =
          TimetableOcr.read(lines, TimetableGridReader.read(lines)!)
              .firstWhere((OcrEntry e) => e.subject == 'BBB2002');
      expect(single.room, 'R102');
      expect(single.teacher, 'CD');
    });

    // A lab drawn as one wide cell has to keep its real length.
    test('a class across two periods keeps both', () {
      final List<OcrLine> lines = _weekOfClasses();
      final Iterable<OcrEntry> doubles =
          TimetableOcr.read(lines, TimetableGridReader.read(lines)!)
              .where((OcrEntry e) => e.to - e.from > 70);
      expect(doubles, hasLength(4));
      expect(doubles.every((OcrEntry e) => e.to - e.from == 100), isTrue);
    });

    // Only the student knows which elective is theirs, so all of them come
    // through as lines to delete rather than one guessed on their behalf.
    test('parallel electives in one cell each get a line', () {
      final Sheet sheet = Sheet()
        ..build()
        ..stack(0, 2, <String>['AAA:XY:R201', 'BBB:ZW:R202', 'CCC:PQ:R203']);
      final List<OcrEntry> entries = TimetableOcr.read(
          sheet.lines, TimetableGridReader.read(sheet.lines)!);
      expect(entries, hasLength(3));
      expect(entries.map((OcrEntry e) => e.subject).toSet(),
          <String>{'AAA', 'BBB', 'CCC'});
      expect(
          entries.every((OcrEntry e) => e.from == entries.first.from), isTrue);
    });

    // A 12-hour sheet drops the meridiem after noon, so `1:35` follows `12:40`
    // and parses three hours before it.
    test('the afternoon is not read as the small hours', () {
      final Sheet sheet = Sheet(headerTexts: <int, String>{
        0: '9:00-9:55',
        1: '9:55-10:50',
        2: '10:50-11:45',
        3: '11:45-12:40',
        4: '12:40-1:35',
        5: '1:35-2:30',
        6: '2:30-3:25',
        7: '3:25-4:20',
        8: '4:20-5:15',
      })
        ..build()
        ..put(0, 6, 'AAA1001', room: 'R101');
      final List<OcrEntry> entries = TimetableOcr.read(
          sheet.lines, TimetableGridReader.read(sheet.lines)!);
      expect(entries.single.from, 14 * 60 + 30);
    });

    // A header that loses a digit makes a start fitting neither neighbour, and
    // the afternoon rule above would then push it further out still.
    test('a start that fits neither neighbour is repaired', () {
      final List<OcrLine> lines =
          _weekOfClasses(headers: <int, String>{3: '1:00- 11:50'});
      final OcrEntry fourth =
          TimetableOcr.read(lines, TimetableGridReader.read(lines)!)
              .firstWhere((OcrEntry e) => e.subject == 'BBB2002');
      expect(fourth.from, greaterThan(10 * 60));
      expect(fourth.from, lessThan(12 * 60));
    });

    test('the transposed sheet yields classes, and no badges', () {
      final List<OcrLine> lines = _transposedSheet();
      final List<OcrEntry> entries =
          TimetableOcr.read(lines, TimetableGridReader.read(lines)!);
      expect(entries, isNotEmpty);
      expect(entries.every((OcrEntry e) => e.to > e.from), isTrue);
      expect(
        entries.any((OcrEntry e) =>
            const <String>{'LECTURE', 'PRACTICAL', 'TUTORIAL'}
                .contains(e.subject.toUpperCase())),
        isFalse,
      );
    });

    test('a line drops the trailing separators it has nothing for', () {
      const OcrEntry bare = OcrEntry(
        subject: 'ABC1234',
        weekday: 3,
        from: 9 * 60 + 10,
        to: 10 * 60,
      );
      expect(bare.toLine(), 'ABC1234, We, 09:10-10:00');
    });
  });
}
