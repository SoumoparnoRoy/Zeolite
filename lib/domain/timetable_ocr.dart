/// A recognised box in image pixels, origin top-left.
///
/// Deliberately not `dart:ui`'s `Rect`: the grid inference below is the part
/// worth testing against saved fixtures with no image and no device, and that
/// only works while this file imports nothing from Flutter.
class OcrBox {
  const OcrBox(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get centreX => (left + right) / 2;
  double get centreY => (top + bottom) / 2;
  double get width => right - left;
  double get height => bottom - top;
}

/// One line of text the recogniser found, and where it sat.
///
/// Lines rather than blocks: a block can swallow a whole column of a timetable,
/// and elements split a room code into digits. A line is a cell's worth.
class OcrLine {
  const OcrLine(this.text, this.box);

  final String text;
  final OcrBox box;
}

/// Which way round a timetable is drawn.
enum GridAxis {
  /// Days run down the page, periods across it — aSc and Symbiosis.
  daysAsRows,

  /// Days run across the page, periods down it.
  daysAsColumns,
}

/// A labelled strip of the image: one weekday, or one period.
class GridBand {
  const GridBand({
    required this.label,
    required this.start,
    required this.end,
    this.weekday,
  });

  /// The recognised text that named this band — `Mo`, `9:10 - 10:00`.
  final String label;

  /// Bounds along the axis the band divides, in image pixels.
  final double start;
  final double end;

  /// 1 = Monday, on a day band. Carried rather than re-read from [label],
  /// because a band recovered from a bare `F` cannot name itself.
  final int? weekday;

  bool contains(double v) => v >= start && v < end;
}

/// The day and period axes recovered from a timetable image.
class TimetableGrid {
  const TimetableGrid({
    required this.axis,
    required this.days,
    required this.periods,
  });

  final GridAxis axis;

  /// Bands in reading order, each labelled with the weekday found in it.
  final List<GridBand> days;

  /// Bands in reading order, each labelled with the header text found in it.
  final List<GridBand> periods;

  /// The weekday and period a box sits in, or null when it sits outside the
  /// table — a title, a legend, a footer.
  ({GridBand day, GridBand period})? cellFor(OcrBox box) {
    final double dayAt = axis == GridAxis.daysAsRows ? box.centreY : box.centreX;
    final double periodAt =
        axis == GridAxis.daysAsRows ? box.centreX : box.centreY;

    GridBand? day;
    for (final GridBand band in days) {
      if (band.contains(dayAt)) day = band;
    }
    GridBand? period;
    for (final GridBand band in periods) {
      if (band.contains(periodAt)) period = band;
    }
    if (day == null || period == null) return null;
    return (day: day, period: period);
  }
}

/// Recovers the grid a timetable image is drawn on.
///
/// The one rule that makes this work across universities: **the axis carrying
/// clock times is the period axis, and the axis carrying weekday names is the
/// day axis.** Everything else about these sheets differs — aSc puts days down
/// the side, another puts them across the top — but no timetable omits either
/// label, so orientation is read rather than configured. That is what keeps a
/// transposed layout from needing its own parser.
class TimetableGridReader {
  static const List<List<String>> _dayWords = <List<String>>[
    <String>['monday', 'mon', 'mo'],
    <String>['tuesday', 'tue', 'tues', 'tu'],
    <String>['wednesday', 'wed', 'we'],
    <String>['thursday', 'thu', 'thur', 'thurs', 'th'],
    <String>['friday', 'fri', 'fr'],
    <String>['saturday', 'sat', 'sa'],
    <String>['sunday', 'sun', 'su'],
  ];

  static final RegExp _clock = RegExp(r'^\d{1,2}[:.]\d{2}$');
  static final RegExp _bareClock = RegExp(r'^\d{3,4}$');
  static final RegExp _clockWithHalf =
      RegExp(r'^(\d{1,2}[:.]\d{2})\s*([ap]\.?m\.?)$', caseSensitive: false);
  static final RegExp _dash = RegExp(r'\s*[-–—]\s*');

  /// The weekday [text] names, 1 = Monday, or null.
  ///
  /// Matched against the whole trimmed line rather than a substring, so a room
  /// called `MONT` or a subject `SATCOM` cannot masquerade as a day.
  static int? weekdayOf(String text) {
    final String key =
        text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (key.isEmpty) return null;
    for (int i = 0; i < _dayWords.length; i++) {
      if (_dayWords[i].contains(key)) return i + 1;
    }
    return null;
  }

  /// Whether [text] is a period header rather than something inside a cell.
  ///
  /// Matched against the *whole* line, never a substring, because a Symbiosis
  /// cell reads `MAL:HKR:B3:510TLI` and the `B3:51` in the middle of it would
  /// otherwise pass for a clock time and invent a column.
  ///
  /// A lost colon is accepted — the recogniser drops it often on a small header
  /// row, giving `910-1000` where the sheet prints `9:10 - 10:00` — but only
  /// when the digits read as a real time, so a course code cannot slip through.
  static bool namesATime(String text) {
    final String line = text.trim();
    final List<String> halves = line.split(_dash);
    if (halves.length == 2 && halves.every(_isClock)) return true;
    return _isClock(line);
  }

  static bool _isClock(String s) {
    final String t = s.trim();
    if (t.isEmpty) return false;
    if (_clockWithHalf.hasMatch(t)) return true;
    if (_clock.hasMatch(t)) return true;
    if (!_bareClock.hasMatch(t)) return false;
    final int value = int.parse(t);
    return value ~/ 100 <= 23 && value % 100 <= 59;
  }

  /// Reads the axes, or null when the image does not look like a timetable —
  /// too few weekdays or no time header to place them against.
  static TimetableGrid? read(List<OcrLine> lines) {
    final List<OcrLine> dayLines = <OcrLine>[
      for (final OcrLine line in lines)
        if (weekdayOf(line.text) != null) line,
    ];
    final List<OcrLine> timeLines = <OcrLine>[
      for (final OcrLine line in lines)
        if (namesATime(line.text)) line,
    ];
    // Two days could be a stray word pair; three is a week.
    if (dayLines.length < 3 || timeLines.length < 2) return null;

    final GridAxis axis = _axisOf(dayLines);
    final bool daysVertical = axis == GridAxis.daysAsRows;

    final Map<OcrLine, int> named =
        _withRecoveredDays(dayLines, lines, vertical: daysVertical);
    final List<GridBand> days = _bandsFrom(
      named.keys.toList(),
      vertical: daysVertical,
      limit: _extentOf(lines, vertical: daysVertical),
      weekdays: named,
    );
    final List<GridBand> periods = _bandsFrom(
      _withMissingPeriods(timeLines, vertical: !daysVertical),
      vertical: !daysVertical,
      limit: _extentOf(lines, vertical: !daysVertical),
    );
    if (days.isEmpty || periods.isEmpty) return null;

    return TimetableGrid(axis: axis, days: days, periods: periods);
  }

  /// Puts back a period column whose header the recogniser lost.
  ///
  /// `15:00 5:50` — its dash gone — is not a time, so that column gets no label
  /// and its classes fall into a neighbour at the wrong hour. Headers sit at a
  /// regular pitch, so a gap of two pitches is a column that is missing and a
  /// blank label goes in at the step where it belongs; its times come from
  /// interpolation between the periods either side.
  ///
  /// Measured on the labels, never on the bands built from them: a band reaches
  /// halfway to each neighbour, so one missing label widens *two* bands by half
  /// a column each and neither looks wrong on its own.
  static List<OcrLine> _withMissingPeriods(
    List<OcrLine> labels, {
    required bool vertical,
  }) {
    if (labels.length < 3) return labels;
    double at(OcrLine l) => vertical ? l.box.centreY : l.box.centreX;

    final List<OcrLine> sorted = <OcrLine>[...labels]
      ..sort((OcrLine a, OcrLine b) => at(a).compareTo(at(b)));
    final double pitch = _medianPitch(sorted.map(at).toList());
    if (pitch <= 0) return labels;

    final List<OcrLine> out = <OcrLine>[...labels];
    for (int i = 0; i + 1 < sorted.length; i++) {
      final double gap = at(sorted[i + 1]) - at(sorted[i]);
      final int steps = (gap / pitch).round();
      if (steps < 2 || gap < pitch * 1.6) continue;
      final double step = gap / steps;
      for (int k = 1; k < steps; k++) {
        final double x = at(sorted[i]) + k * step;
        final OcrBox box = vertical
            ? OcrBox(sorted[i].box.left, x - 1, sorted[i].box.right, x + 1)
            : OcrBox(x - 1, sorted[i].box.top, x + 1, sorted[i].box.bottom);
        out.add(OcrLine('', box));
      }
    }
    return out;
  }

  /// Adds back a weekday the recogniser mangled past recognition.
  ///
  /// The aSc sheet returns `F` for Friday, which no word list should accept on
  /// its own — but the four days above it sit at a regular pitch, so the sheet
  /// itself says where Friday must be and which day it must name. A candidate
  /// is taken only when it sits on that step, shares the column the other day
  /// labels use, and starts with the letter the sequence predicts. Losing a day
  /// silently drops a fifth of the timetable, which is worse than any of the
  /// misreads the preview screen can catch.
  static Map<OcrLine, int> _withRecoveredDays(
    List<OcrLine> dayLines,
    List<OcrLine> all, {
    required bool vertical,
  }) {
    double along(OcrLine l) => vertical ? l.box.centreY : l.box.centreX;
    double across(OcrLine l) => vertical ? l.box.centreX : l.box.centreY;

    final List<OcrLine> known = <OcrLine>[...dayLines]
      ..sort((OcrLine a, OcrLine b) => along(a).compareTo(along(b)));
    final Map<OcrLine, int> found = <OcrLine, int>{
      for (final OcrLine l in dayLines) l: weekdayOf(l.text)!,
    };
    final double pitch = _medianPitch(known.map(along).toList());
    if (pitch <= 0) return found;

    final double lane =
        known.map(across).reduce((double a, double b) => a + b) / known.length;
    final double laneWidth = pitch;

    final Set<int> haveDays = found.values.toSet();

    for (final OcrLine line in all) {
      final String letters =
          line.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      // A bare initial only. Anything longer that still failed the word list is
      // some other text — a legend entry sitting under the table shares this
      // column, and two of its letters were enough to fake a Saturday.
      if (letters.length != 1) continue;

      final List<int> candidates = <int>[
        for (int d = 1; d <= 7; d++)
          if (!haveDays.contains(d) && _dayWords[d - 1].first[0] == letters) d,
      ];
      // Saturday and Sunday share an S, so a lone `S` names nothing until one
      // of them is already accounted for.
      if (candidates.length != 1) continue;
      final int wanted = candidates.single;

      final OcrLine anchor = known.first;
      final double target =
          along(anchor) + (wanted - weekdayOf(anchor.text)!) * pitch;
      if ((along(line) - target).abs() > pitch * 0.35) continue;
      if ((across(line) - lane).abs() > laneWidth) continue;

      found[line] = wanted;
      haveDays.add(wanted);
    }
    return found;
  }

  /// Days stacked down the page vary in y and share an x; days across the top
  /// do the opposite. Comparing the two spreads is enough and needs no ruling
  /// lines, which is what makes it survive a screenshot with no borders.
  static GridAxis _axisOf(List<OcrLine> dayLines) {
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    for (final OcrLine line in dayLines) {
      minX = line.box.centreX < minX ? line.box.centreX : minX;
      maxX = line.box.centreX > maxX ? line.box.centreX : maxX;
      minY = line.box.centreY < minY ? line.box.centreY : minY;
      maxY = line.box.centreY > maxY ? line.box.centreY : maxY;
    }
    return (maxY - minY) >= (maxX - minX)
        ? GridAxis.daysAsRows
        : GridAxis.daysAsColumns;
  }

  /// Turns labels into bands that meet at the midpoints between them, so every
  /// pixel between the first and last label belongs to exactly one band.
  ///
  /// The outer edges step half a band past the outermost labels rather than
  /// reaching the content's extent: a legend or a footer printed under the
  /// table would otherwise fall inside the last weekday and import as classes.
  /// Half a band is right because these rows are near-uniform by construction.
  static List<GridBand> _bandsFrom(
    List<OcrLine> labels, {
    required bool vertical,
    required (double, double) limit,
    Map<OcrLine, int>? weekdays,
  }) {
    double at(OcrLine l) => vertical ? l.box.centreY : l.box.centreX;

    final List<OcrLine> sorted = <OcrLine>[...labels]
      ..sort((OcrLine a, OcrLine b) => at(a).compareTo(at(b)));

    // One label per position: a time header printed as two lines ("1" above
    // "9:10 - 10:00") would otherwise split its own column in half.
    final List<OcrLine> unique = <OcrLine>[];
    for (final OcrLine line in sorted) {
      if (unique.isEmpty) {
        unique.add(line);
        continue;
      }
      final double gap = at(line) - at(unique.last);
      final double tolerance =
          (vertical ? line.box.height : line.box.width) * 1.5;
      if (gap > tolerance) unique.add(line);
    }
    if (unique.isEmpty) return const <GridBand>[];

    final double half = _medianPitch(unique.map(at).toList()) / 2;
    final List<GridBand> bands = <GridBand>[];
    for (int i = 0; i < unique.length; i++) {
      final double start = i == 0
          ? _atLeast(at(unique.first) - half, limit.$1)
          : (at(unique[i - 1]) + at(unique[i])) / 2;
      final double end = i == unique.length - 1
          ? _atMost(at(unique.last) + half, limit.$2)
          : (at(unique[i]) + at(unique[i + 1])) / 2;
      bands.add(GridBand(
        label: unique[i].text.trim(),
        start: start,
        end: end,
        weekday: weekdays?[unique[i]],
      ));
    }
    return bands;
  }

  /// The typical distance between neighbouring labels. Median rather than mean
  /// so one missed label — a weekday the recogniser dropped — widens its own
  /// gap without stretching every band on the sheet.
  static double _medianPitch(List<double> centres) {
    if (centres.length < 2) return 0;
    final List<double> gaps = <double>[
      for (int i = 1; i < centres.length; i++) centres[i] - centres[i - 1],
    ]..sort();
    return gaps[gaps.length ~/ 2];
  }

  static double _atLeast(double v, double floor) => v < floor ? floor : v;
  static double _atMost(double v, double ceiling) => v > ceiling ? ceiling : v;

  static (double, double) _extentOf(List<OcrLine> lines,
      {required bool vertical}) {
    double lo = double.infinity, hi = -double.infinity;
    for (final OcrLine line in lines) {
      final double a = vertical ? line.box.top : line.box.left;
      final double b = vertical ? line.box.bottom : line.box.right;
      if (a < lo) lo = a;
      if (b > hi) hi = b;
    }
    return (lo, hi);
  }
}

/// One class read out of a cell, before it becomes a line of the paste format.
class OcrEntry {
  const OcrEntry({
    required this.subject,
    required this.weekday,
    required this.from,
    required this.to,
    this.room,
    this.teacher,
  });

  final String subject;
  final int weekday;

  /// Minutes since midnight, taken from the period header the class sits under.
  final int from;
  final int to;

  final String? room;
  final String? teacher;

  /// The line the paste format already parses.
  String toLine() {
    const List<String> days = <String>['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
    final List<String> fields = <String>[
      subject,
      days[weekday - 1],
      '${_hhmm(from)}-${_hhmm(to)}',
      room ?? '',
      teacher ?? '',
    ];
    // Trailing empties go: the format treats room and teacher as optional, and
    // a line ending in commas reads as a mistake rather than an omission.
    while (fields.length > 3 && fields.last.isEmpty) {
      fields.removeLast();
    }
    return fields.join(', ');
  }

  static String _hhmm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

/// Turns recognised boxes into lines of the timetable paste format.
///
/// Every candidate is emitted rather than a best guess: one cell can hold five
/// parallel electives and only the student knows which is theirs, so all five
/// become lines and the preview screen is where four get deleted.
class TimetableOcr {
  /// A course code — letters and digits together, which is how all three of
  /// these sheets name a class.
  static final RegExp _code = RegExp(r'^[A-Z]{2,5}-?\d{2,5}[A-Z]?$');

  /// A room: `B204`, `B311A`, `509`, `LT401`, `L208`.
  static final RegExp _room = RegExp(r'^[A-Z]{0,3}-?\d{2,4}[A-Z]?$');

  /// Initials, as the teacher column and the legend both print them.
  static final RegExp _initials = RegExp(r'^[A-Z]{2,4}$');

  /// Initials glued to a room, which the small bottom row does often:
  /// `ABB204`, `CDB311`. Splitting these is most of what that row needs.
  static final RegExp _initialsAndRoom =
      RegExp(r'^([A-Z]{2,3})(B\d{2,4}[A-Z]?)$');

  static final RegExp _digit = RegExp(r'\d');
  static final RegExp _splitTokens = RegExp(r'[\s,]+');
  static final RegExp _bareClock = RegExp(r'^\d{3,4}$');

  static List<String> toLines(List<OcrLine> lines, TimetableGrid grid) =>
      read(lines, grid).map((OcrEntry e) => e.toLine()).toList();

  static List<OcrEntry> read(List<OcrLine> lines, TimetableGrid grid) {
    final Map<String, List<OcrLine>> cells = <String, List<OcrLine>>{};
    final Map<String, GridBand> dayOf = <String, GridBand>{};

    for (final OcrLine line in lines) {
      if (TimetableGridReader.namesATime(line.text)) continue;
      if (TimetableGridReader.weekdayOf(line.text) != null) continue;
      final ({GridBand day, GridBand period})? cell = grid.cellFor(line.box);
      if (cell == null || cell.day.weekday == null) continue;
      final String key = '${cell.day.weekday}@${cell.period.start}';
      cells.putIfAbsent(key, () => <OcrLine>[]).add(line);
      dayOf[key] = cell.day;
    }

    final List<(int, int)?> schedule = _scheduleOf(grid);

    final List<OcrEntry> out = <OcrEntry>[];
    for (final MapEntry<String, List<OcrLine>> cell in cells.entries) {
      final int weekday = dayOf[cell.key]!.weekday!;
      for (final _Candidate c in _candidatesIn(cell.value)) {
        final (int, int)? span = _spanOf(c.box, grid, schedule);
        if (span == null) continue;
        out.add(OcrEntry(
          subject: c.subject,
          weekday: weekday,
          from: span.$1,
          to: span.$2,
          room: c.room,
          teacher: c.teacher,
        ));
      }
    }
    out.sort((OcrEntry a, OcrEntry b) =>
        a.weekday != b.weekday ? a.weekday - b.weekday : a.from - b.from);
    return out;
  }

  /// Splits one cell into the classes it offers.
  ///
  /// Text stacks vertically whichever way the sheet is drawn, so sub-rows group
  /// by y in both layouts. A sub-row naming a subject opens a candidate;
  /// anything else — a room, initials, the prose course name, a `PRACTICAL`
  /// badge — is detail belonging to the one above it.
  static List<_Candidate> _candidatesIn(List<OcrLine> cell) {
    final List<List<OcrLine>> rows = _rowsOf(cell);
    final List<({String text, OcrBox box})> lines = <({String text, OcrBox box})>[
      for (final List<OcrLine> row in rows)
        (
          text: row.map((OcrLine l) => l.text).join(' ').trim(),
          box: _hullOf(row),
        ),
    ];

    // Colon-packed rows are the shape that stacks parallel electives into one
    // cell, and only that shape means a cell holds more than one class. Every
    // other sheet draws one class per cell across several rows — a badge, the
    // course name, its code, its room — so splitting on rows there would turn
    // one class into four.
    final bool stacked =
        lines.any((({String text, OcrBox box}) l) => _isPacked(l.text));
    if (stacked) {
      final List<_Candidate> found = <_Candidate>[];
      for (final ({String text, OcrBox box}) line in lines) {
        if (!_isPacked(line.text)) {
          if (found.isNotEmpty) _attach(found.last, line.text.split(_splitTokens));
          continue;
        }
        final List<String> parts =
            line.text.split(':').map((String s) => s.trim()).toList();
        found.add(_Candidate(
          subject: parts.first,
          box: line.box,
          teacher: parts.length > 1 ? parts[1] : null,
          room: parts.skip(1).where(_looksLikeRoom).firstOrNull,
        ));
      }
      return found;
    }

    // One class. The code names it when there is one — it is what repeats
    // across days, where the printed name wraps differently in every cell.
    final List<String> tokens = <String>[
      for (final ({String text, OcrBox box}) l in lines)
        ...l.text.split(_splitTokens).where((String t) => t.isNotEmpty),
    ];
    final String? code = tokens.where((String t) => _code.hasMatch(t)).firstOrNull;

    String? subject = code;
    if (subject == null) {
      final List<({String text, OcrBox box})> naming = lines
          .where((({String text, OcrBox box}) l) =>
              l.text.isNotEmpty && !_isBadge(l.text) && !_allDetail(l.text.split(_splitTokens)))
          .toList();
      if (naming.isEmpty) return const <_Candidate>[];
      naming.sort((({String text, OcrBox box}) a, ({String text, OcrBox box}) b) =>
          b.text.length.compareTo(a.text.length));
      subject = naming.first.text;
    }

    // The span comes from the row that names the class, never the whole cell:
    // the room and teacher run the full width of a cell and bleed into the
    // period on either side, which stretched a one-period class across two.
    final ({String text, OcrBox box}) naming = lines.firstWhere(
      (({String text, OcrBox box}) l) => l.text.contains(subject!),
      orElse: () => lines.first,
    );
    final _Candidate one = _Candidate(subject: subject, box: naming.box);
    _attach(one, tokens.where((String t) => t != subject));
    return <_Candidate>[one];
  }

  static bool _isPacked(String text) => ':'.allMatches(text).length >= 2;

  /// The class-type label some sheets print above the name. It is not a
  /// subject, and the app has categories for what it says.
  static bool _isBadge(String text) => const <String>{
        'lecture',
        'practical',
        'tutorial',
        'lab',
        'minor',
        'minors',
        'honors',
      }.contains(text.trim().toLowerCase());

  static bool _allDetail(List<String> tokens) => tokens
      .every((String t) => _looksLikeRoom(t) || _initials.hasMatch(t));

  /// Reads a room and a teacher out of whatever else the cell holds.
  static void _attach(_Candidate c, Iterable<String> tokens) {
    for (final String raw in tokens) {
      final String cleaned = raw.replaceAll(RegExp(r'[()]'), ' ').trim();
      if (cleaned.isEmpty) continue;

      final RegExpMatch? glued = _initialsAndRoom.firstMatch(cleaned);
      if (glued != null) {
        c.teacher ??= glued.group(1);
        c.room ??= glued.group(2);
        continue;
      }
      for (final String part in cleaned.split(RegExp(r'\s+'))) {
        if (part.isEmpty) continue;
        if (_looksLikeRoom(part)) {
          c.room ??= part;
        } else if (_initials.hasMatch(part)) {
          c.teacher ??= part;
        }
      }
    }
  }

  /// A room needs a digit in it, so a bare word never becomes one — but a bare
  /// number that reads as a clock is a stray header, not room 930.
  static bool _looksLikeRoom(String raw) {
    final String t = raw.trim();
    if (!_room.hasMatch(t) || !_digit.hasMatch(t)) return false;
    return !_bareClock.hasMatch(t) || !TimetableGridReader.namesATime(t);
  }

  /// Groups a cell's lines into the rows they read as.
  static List<List<OcrLine>> _rowsOf(List<OcrLine> cell) {
    final List<OcrLine> sorted = <OcrLine>[...cell]
      ..sort((OcrLine a, OcrLine b) => a.box.centreY.compareTo(b.box.centreY));
    final List<List<OcrLine>> rows = <List<OcrLine>>[];
    for (final OcrLine line in sorted) {
      if (rows.isNotEmpty) {
        final OcrLine last = rows.last.last;
        // One row while the baselines sit within a third of a line's height.
        if ((line.box.centreY - last.box.centreY).abs() <
            (last.box.height + line.box.height) / 3) {
          rows.last.add(line);
          continue;
        }
      }
      rows.add(<OcrLine>[line]);
    }
    for (final List<OcrLine> row in rows) {
      row.sort((OcrLine a, OcrLine b) => a.box.left.compareTo(b.box.left));
    }
    return rows;
  }

  static OcrBox _hullOf(List<OcrLine> row) {
    double l = row.first.box.left;
    double t = row.first.box.top;
    double r = row.first.box.right;
    double b = row.first.box.bottom;
    for (final OcrLine line in row) {
      if (line.box.left < l) l = line.box.left;
      if (line.box.top < t) t = line.box.top;
      if (line.box.right > r) r = line.box.right;
      if (line.box.bottom > b) b = line.box.bottom;
    }
    return OcrBox(l, t, r, b);
  }

  /// The clock span a candidate covers, widened across every period band it
  /// overlaps — which is how a lab drawn as one wide cell keeps its real length
  /// instead of collapsing to a single period.
  /// Every period's clock span, read once.
  ///
  /// Two things go wrong in a header row and they have to be told apart. These
  /// sheets print a 12-hour clock and drop the meridiem after noon, so `1:35`
  /// follows `12:40` and parses three hours *earlier* — that reading needs
  /// twelve hours added. But a header can also lose a digit, `11:40` coming
  /// back as `1:40`, and adding twelve hours there invents a time the sheet
  /// never printed and drags the next period after it.
  ///
  /// Periods are evenly spaced, so both are settled the same way: take whichever
  /// reading lands nearest where the period before it says the next one starts,
  /// and if neither lands anywhere near, treat the header as unreadable and
  /// interpolate it from its neighbours.
  static List<(int, int)?> _scheduleOf(TimetableGrid grid) {
    final List<int?> raw = <int?>[
      for (final GridBand band in grid.periods) _startOf(band),
    ];
    final int pitch = _usualGap(raw);

    final List<int?> starts = List<int?>.filled(raw.length, null);
    int? previous;
    int lastIndex = -1;
    for (int i = 0; i < raw.length; i++) {
      final int? at = raw[i];
      if (at == null) continue;
      if (previous == null) {
        starts[i] = at;
        previous = at;
        lastIndex = i;
        continue;
      }
      final int target = previous + pitch * (i - lastIndex);
      int? best;
      int bestOff = 0;
      for (final int candidate in <int>[at, at + 720]) {
        if (candidate <= previous || candidate >= 1440) continue;
        final int off = (candidate - target).abs();
        if (best == null || off < bestOff) {
          best = candidate;
          bestOff = off;
        }
      }
      if (best == null || bestOff > pitch * 3 ~/ 2) continue;
      starts[i] = best;
      previous = best;
      lastIndex = i;
    }
    _interpolate(starts);

    return <(int, int)?>[
      for (int i = 0; i < starts.length; i++)
        if (starts[i] == null)
          null
        else
          (starts[i]!, _endFor(grid, starts, i) ?? starts[i]! + pitch),
    ];
  }

  /// The usual step between one period and the next, ignoring the backwards
  /// steps a 12-hour clock and a misread both produce.
  static int _usualGap(List<int?> raw) {
    final List<int> gaps = <int>[];
    int? previous;
    for (final int? at in raw) {
      if (at == null) continue;
      if (previous != null && at > previous) gaps.add(at - previous);
      previous = at;
    }
    if (gaps.isEmpty) return 50;
    gaps.sort();
    return gaps[gaps.length ~/ 2];
  }

  /// Fills gaps by spreading evenly between the periods either side, which is
  /// what a uniform column grid means.
  static void _interpolate(List<int?> starts) {
    for (int i = 0; i < starts.length; i++) {
      if (starts[i] != null) continue;
      int before = i - 1;
      while (before >= 0 && starts[before] == null) {
        before--;
      }
      int after = i + 1;
      while (after < starts.length && starts[after] == null) {
        after++;
      }
      if (before < 0 || after >= starts.length) continue;
      final int span = starts[after]! - starts[before]!;
      final int steps = after - before;
      starts[i] = starts[before]! + span * (i - before) ~/ steps;
    }
  }

  /// A header printing only a start — the transposed sheet does — takes its end
  /// from where the next period begins; the last period of the day borrows the
  /// length of the one before it.
  static int? _endFor(TimetableGrid grid, List<int?> starts, int index) {
    final List<String> halves = _halves(grid.periods[index].label);
    if (halves.length > 1) {
      final int? explicit = _minutes(halves.last);
      // The end is on the same clock as the start it follows.
      if (explicit != null) {
        int end = explicit;
        while (end < starts[index]! && end + 720 < 1440) {
          end += 720;
        }
        if (end > starts[index]!) return end;
      }
    }
    for (int j = index + 1; j < starts.length; j++) {
      if (starts[j] != null && starts[j]! > starts[index]!) return starts[j];
    }
    for (int j = index - 1; j >= 0; j--) {
      if (starts[j] != null && starts[index]! > starts[j]!) {
        return starts[index]! + (starts[index]! - starts[j]!);
      }
    }
    return null;
  }

  static (int, int)? _spanOf(
      OcrBox box, TimetableGrid grid, List<(int, int)?> schedule) {
    final bool acrossX = grid.axis == GridAxis.daysAsRows;
    final double lo = acrossX ? box.left : box.top;
    final double hi = acrossX ? box.right : box.bottom;

    // A real overlap, not a touch: recognised boxes overshoot their cell by a
    // pixel or two, which was enough to claim the period next door.
    final List<int> touched = <int>[];
    for (int i = 0; i < grid.periods.length; i++) {
      final GridBand band = grid.periods[i];
      final double over =
          (hi < band.end ? hi : band.end) - (lo > band.start ? lo : band.start);
      final double smaller =
          (hi - lo) < (band.end - band.start) ? hi - lo : band.end - band.start;
      if (over > smaller * 0.25) touched.add(i);
    }
    if (touched.isEmpty) return null;

    final (int, int)? first = schedule[touched.first];
    final (int, int)? last = schedule[touched.last];
    if (first == null || last == null || last.$2 <= first.$1) return null;
    return (first.$1, last.$2);
  }

  static int? _startOf(GridBand band) => _minutes(_halves(band.label).first);

  static List<String> _halves(String label) =>
      label.split(RegExp(r'\s*[-–—]\s*')).map((String s) => s.trim()).toList();

  /// Minutes since midnight, taking `9:10`, `0910` and `1:00PM` alike.
  static int? _minutes(String raw) {
    final String t = raw.trim();
    int? hour;
    int? minute;
    final RegExpMatch? m =
        RegExp(r'^(\d{1,2})[:.](\d{2})\s*([ap])?', caseSensitive: false)
            .firstMatch(t);
    if (m != null) {
      hour = int.parse(m.group(1)!);
      minute = int.parse(m.group(2)!);
      final String? half = m.group(3)?.toLowerCase();
      if (half == 'p' && hour < 12) hour += 12;
      if (half == 'a' && hour == 12) hour = 0;
    } else if (_bareClock.hasMatch(t)) {
      final int v = int.parse(t);
      hour = v ~/ 100;
      minute = v % 100;
    }
    if (hour == null || minute == null) return null;
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }
}

class _Candidate {
  _Candidate({
    required this.subject,
    required this.box,
    this.room,
    this.teacher,
  });

  final String subject;
  final OcrBox box;
  String? room;
  String? teacher;
}
