import 'timetable_ocr.dart';

/// One course as a portal reports it: how many sessions the term holds, how
/// many have been marked so far, and how many of those were attended.
///
/// The names match [Subject]'s three columns rather than the portal's headers,
/// because that is where every one of them ends up.
class TotalsRow {
  const TotalsRow({
    required this.subject,
    required this.expectedTotal,
    required this.held,
    required this.attended,
    this.printedPercent,
    this.namesTwoCourses = false,
  });

  final String subject;

  /// Null when the term total was the one cell that could not be read. It maps
  /// onto [Subject.expectedTotal], which is nullable for the same reason: the
  /// app falls back to counting the timetable when nothing declares a total.
  final int? expectedTotal;

  final int held;
  final int attended;

  /// The percentage the portal printed, when the column was readable.
  final double? printedPercent;

  /// Set when the name still carries a term stamp in the middle of it, which
  /// only happens when one course's row lost its numbers and its name was
  /// swept into the row below.
  final bool namesTwoCourses;

  /// Whether the printed percentage agrees with the two numbers beside it.
  ///
  /// This is the check a timetable sheet could never offer: the portal shows
  /// its own working, so a misread digit contradicts itself instead of
  /// importing quietly. Half a point of slack covers the rounding.
  bool get percentAgrees {
    final double? printed = printedPercent;
    if (printed == null) return true;
    if (held == 0) return attended == 0;
    return (attended * 100 / held - printed).abs() < 0.55;
  }

  /// A row cannot attend more than was held, or hold more than the term has.
  bool get isOrdered {
    final int? total = expectedTotal;
    return attended <= held && (total == null || held <= total);
  }

  bool get isTrustworthy => percentAgrees && isOrdered && !namesTwoCourses;

  TotalsRow withTotal(int total) => TotalsRow(
        subject: subject,
        expectedTotal: total,
        held: held,
        attended: attended,
        printedPercent: printedPercent,
        namesTwoCourses: namesTwoCourses,
      );
}

/// A whole portal page, with the two figures it prints at the foot.
class AttendanceTotals {
  const AttendanceTotals({
    required this.rows,
    this.printedTotal,
    this.printedAttended,
  });

  final List<TotalsRow> rows;

  /// "Total Session: 174" and "Total Attended Session: 135", when present.
  final int? printedTotal;
  final int? printedAttended;

  int get totalSum => rows.fold<int>(
        0,
        (int sum, TotalsRow r) => sum + (r.expectedTotal ?? 0),
      );

  int get attendedSum =>
      rows.fold<int>(0, (int sum, TotalsRow r) => sum + r.attended);

  /// The footer totals are a checksum the page hands over for free: if the
  /// rows do not add up to them, a row was missed or misread even when every
  /// row agrees with its own percentage.
  bool get addsUp =>
      (printedTotal == null || printedTotal == totalSum) &&
      (printedAttended == null || printedAttended == attendedSum);

  List<TotalsRow> get suspect =>
      rows.where((TotalsRow r) => !r.isTrustworthy).toList();
}

/// Reads a portal's per-subject attendance table out of recognised text.
///
/// Far simpler than the timetable grid next door: this is a real table, so the
/// only geometry needed is which lines share a row. Rows are anchored on the
/// number cells rather than on every line, because a course name wraps onto a
/// second line and clustering by text position alone would split it in two.
class AttendanceTotalsOcr {
  /// A cell's rule reads as a character glued to what it contains, so `21`
  /// comes back as `|21` about a third of the time on a table drawn with
  /// borders. Rejecting those loses one number out of a row, and a row short
  /// of a number is dropped entirely.
  static const String _rule = r'[|Il!\[\]/\ ]*';

  static final RegExp _int = RegExp('^$_rule' r'(\d{1,4})' '$_rule\$');

  static final RegExp _percent =
      RegExp('^$_rule' r'(\d{1,3}(?:[.,]\d+)?)\s*%' '$_rule\$');

  /// What a portal prints where a percentage would go for a course that has
  /// held nothing yet. Dropped rather than kept, or it lands in the name.
  static final RegExp _blankCell = RegExp(r'^[-–—.\s]*$');

  /// A dash is a cell, not an absence: anchoring rows on integers alone leaves
  /// a course that has held nothing with no band of its own, and its name is
  /// swept into the neighbour it then refuses.
  static bool _isBlankCell(String text) {
    final String trimmed = text.trim();
    return trimmed.isNotEmpty && _blankCell.hasMatch(trimmed);
  }

  /// A term stamp the portal appends to every course: `_Odd_2026-27`. It wraps
  /// mid-suffix on a narrow screenshot, which is why it is stripped after the
  /// name's lines are joined rather than before.
  ///
  /// `[o0]` because the recogniser reads the capital O of "Odd" as a zero
  /// about half the time, and a stamp left on the name makes two readings of
  /// the same course look like two different subjects.
  static const String _term = r'([o0]dd|even|sem(ester)?\s*\d*)';

  static final RegExp _termStamp = RegExp(
    r'[_\s]*' '$_term' r'?[_\s]*\d{4}\s*-?\s*\d{0,4}$',
    caseSensitive: false,
  );

  /// The same stamp anywhere but the end, which means two rows were read as
  /// one — the second course's name landed in the first course's band.
  ///
  /// What follows has to contain a letter. A cell the recogniser glued onto
  /// the name leaves digits after the stamp, and that is one course with a
  /// misread cell rather than two courses.
  static final RegExp _stampInside = RegExp(
    r'[_\s]' '$_term' r'[_\s]*\d{4}\s*-?\s*\d{0,4}[_\s]+\S*[A-Za-z]',
    caseSensitive: false,
  );

  static final RegExp _letter = RegExp('[A-Za-z]');

  /// A number cell that came back glued to the name beside it.
  ///
  /// Group 1 is the rule and space between the two and has to be there:
  /// without it the `27` of `_Odd_2026-27` is a cell as well.
  static final RegExp _trailingCell = RegExp(
    '($_rule)' r'(\d{1,3}(?:[.,]\d+)?\s*%|\d{1,4})' '$_rule' r'$',
  );

  static final RegExp _footerTotal =
      RegExp(r'total\s*sessions?\s*[:\-]?\s*(\d{1,5})', caseSensitive: false);
  static final RegExp _footerAttended = RegExp(
    r'total\s*attended\s*sessions?\s*[:\-]?\s*(\d{1,5})',
    caseSensitive: false,
  );

  static final RegExp _footerPercent =
      RegExp(r'total\s*percentage', caseSensitive: false);

  /// The last row's band has no row below to bound it, so every footer line
  /// falls into it and ends up in that course's name.
  static bool _isFooter(String text) =>
      _footerTotal.hasMatch(text) ||
      _footerAttended.hasMatch(text) ||
      _footerPercent.hasMatch(text);

  /// Whether this image is a totals table at all, rather than a timetable.
  ///
  /// Checked on the header words instead of the shape, so the caller can
  /// choose a parser before paying for either.
  static bool looksLikeTotals(List<OcrLine> lines) {
    bool has(String word) => lines.any(
          (OcrLine l) => l.text.toLowerCase().contains(word),
        );
    return has('attended') && (has('percentage') || has('marked'));
  }

  /// Where the three number columns sit, for a caller that can read part of an
  /// image on its own.
  ///
  /// Taken off the header rather than off the cells, because the cells are
  /// exactly what is missing when this is worth doing.
  static OcrBox? numberColumns(List<OcrLine> lines) {
    final double headerBottom = _headerBottom(lines);
    double left = double.infinity;
    double right = double.negativeInfinity;
    for (final OcrLine line in lines) {
      if (line.box.centreY > headerBottom) continue;
      final String text = line.text.toLowerCase();
      final bool numeric = (text.contains('total') ||
              text.contains('marked') ||
              text.contains('attended') ||
              text.contains('session')) &&
          !text.contains('percentage') &&
          !text.contains('course') &&
          !text.contains('name');
      if (!numeric) continue;
      if (line.box.left < left) left = line.box.left;
      if (line.box.right > right) right = line.box.right;
    }
    if (left >= right) return null;

    double bottom = double.negativeInfinity;
    for (final OcrLine line in lines) {
      if (line.box.bottom > bottom) bottom = line.box.bottom;
    }
    return OcrBox(left, 0, right, bottom);
  }

  /// [cells] is a second, sharper reading of [numberColumns] when the caller
  /// managed one: the digits come from there and everything else — names,
  /// percentages, the footer — from [lines].
  static AttendanceTotals? read(
    List<OcrLine> lines, {
    List<OcrLine>? cells,
  }) {
    if (!looksLikeTotals(lines)) return null;

    final double headerBottom = _headerBottom(lines);
    final List<OcrLine> peeled = <OcrLine>[];
    final List<OcrLine> body = <OcrLine>[
      for (final OcrLine line
          in _splitTrailingCells(lines, numberColumns(lines), peeled))
        if (line.box.centreY > headerBottom) line,
    ];

    // A cell peeled off a name is one the sharper read did not return either,
    // or the name would not have carried it, so it joins [cells] rather than
    // competing with it.
    final List<OcrLine> read = cells == null
        ? body
        : <OcrLine>[...cells, ...peeled];
    final List<OcrLine> numbers = <OcrLine>[
      for (final OcrLine line in read)
        if (line.box.centreY > headerBottom &&
            (_intOf(line.text) != null || _isBlankCell(line.text)))
          line,
    ];

    final List<double> rowCentres = _rowCentres(numbers);
    if (rowCentres.length < 2) return null;

    // Digits only: a dash anchors a row but sits in the percentage column, and
    // letting it name a column shifts all three one place to the right.
    final List<double> columns = _columnCentres(<OcrLine>[
      for (final OcrLine l in numbers)
        if (_intOf(l.text) != null) l,
    ]);

    final List<TotalsRow> rows = <TotalsRow>[];
    for (int i = 0; i < rowCentres.length; i++) {
      final double top = i == 0
          ? double.negativeInfinity
          : (rowCentres[i - 1] + rowCentres[i]) / 2;
      final double bottom = i == rowCentres.length - 1
          ? double.infinity
          : (rowCentres[i] + rowCentres[i + 1]) / 2;
      bool inBand(OcrLine l) =>
          l.box.centreY > top && l.box.centreY <= bottom;

      final TotalsRow? row = _rowFrom(
        band: <OcrLine>[
          for (final OcrLine l in body)
            if (inBand(l)) l,
        ],
        cells: <OcrLine>[
          for (final OcrLine l in numbers)
            if (inBand(l)) l,
        ],
        columns: columns,
      );
      if (row != null) rows.add(row);
    }
    if (rows.isEmpty) return null;

    final int? printedTotal =
        _footerValue(lines, _footerTotal, skip: _footerAttended);
    final int? printedAttended = _footerValue(lines, _footerAttended);

    final List<TotalsRow> filled = _fillLastTotal(rows, printedTotal);
    final AttendanceTotals page = AttendanceTotals(
      rows: filled,
      printedTotal: printedTotal,
      printedAttended: printedAttended,
    );

    // A page's own total cannot be smaller than the rows it is made of, so a
    // footer below the sum was misread rather than contradicted — the number
    // sits in a coloured band and loses digits easily. Dropping it says
    // nothing, which beats claiming the page disagrees when it does not.
    return AttendanceTotals(
      rows: filled,
      printedTotal: (page.printedTotal ?? page.totalSum) < page.totalSum
          ? null
          : page.printedTotal,
      printedAttended:
          (page.printedAttended ?? page.attendedSum) < page.attendedSum
              ? null
              : page.printedAttended,
    );
  }

  /// Peels cells the recogniser read as part of the name back off it.
  ///
  /// One merge costs a row twice: the number is lost, and the term stamp is
  /// left in the middle of the name, where [_stampInside] reads it as two
  /// courses run together and refuses the row outright.
  ///
  /// A cell has to reach into [block], the number columns off the header,
  /// which is what stops a course whose name genuinely ends in a digit from
  /// being cut short. Position within the line is apportioned by character
  /// count, which is rough — the gap the recogniser swallowed is one space in
  /// the text and most of a column on the page.
  static List<OcrLine> _splitTrailingCells(
    List<OcrLine> lines,
    OcrBox? block,
    List<OcrLine> into,
  ) {
    if (block == null) return lines;
    final List<OcrLine> split = <OcrLine>[];
    for (final OcrLine line in lines) {
      final String raw = line.text;
      // The footer carries a number of its own, and cutting it loose leaves a
      // cell below the last row that would anchor a row that is not there.
      if (raw.isEmpty || _isFooter(raw)) {
        split.add(line);
        continue;
      }
      final double perChar = line.box.width / raw.length;
      double x(int i) => line.box.left + perChar * i;

      int end = raw.trimRight().length;
      final List<OcrLine> cells = <OcrLine>[];
      while (true) {
        final RegExpMatch? match =
            _trailingCell.firstMatch(raw.substring(0, end));
        if (match == null ||
            match.group(1)!.isEmpty ||
            !_letter.hasMatch(raw.substring(0, match.start))) {
          break;
        }
        // Measured on the cell's right edge, which for the first one off a
        // line is the line's own and needs no apportioning at all.
        final double right = x(end);
        if (right <= block.left) break;
        cells.add(
          OcrLine(
            raw.substring(match.start, end).trim(),
            OcrBox(x(match.start), line.box.top, right, line.box.bottom),
          ),
        );
        end = match.start;
      }
      if (cells.isEmpty) {
        split.add(line);
        continue;
      }
      into.addAll(cells);
      split
        ..add(
          OcrLine(
            raw.substring(0, end),
            OcrBox(line.box.left, line.box.top, x(end), line.box.bottom),
          ),
        )
        ..addAll(cells.reversed);
    }
    return split;
  }

  /// The page's own total pins the one term total that could not be read.
  ///
  /// Only ever with a single unknown left: two of them and the residual could
  /// be split any number of ways, which is guessing rather than deriving.
  static List<TotalsRow> _fillLastTotal(List<TotalsRow> rows, int? printed) {
    if (printed == null) return rows;
    final List<int> unknown = <int>[
      for (int i = 0; i < rows.length; i++)
        if (rows[i].expectedTotal == null) i,
    ];
    if (unknown.length != 1) return rows;

    final int known = rows.fold<int>(
      0,
      (int sum, TotalsRow r) => sum + (r.expectedTotal ?? 0),
    );
    final int residual = printed - known;
    final TotalsRow row = rows[unknown.first];
    if (residual < row.held) return rows;
    return <TotalsRow>[
      for (int i = 0; i < rows.length; i++)
        i == unknown.first ? row.withTotal(residual) : rows[i],
    ];
  }

  static const List<String> _headerWords = <String>[
    'course',
    'name',
    'total',
    'marked',
    'attended',
    'session',
    'percentage',
  ];

  /// The foot of the header, so everything below it is data.
  ///
  /// Bounded by the first number on the page rather than by the words alone:
  /// a header column wraps onto a second line that has to be excluded too,
  /// while the footer repeats the very same words underneath every row.
  static double _headerBottom(List<OcrLine> lines) {
    double firstNumber = double.infinity;
    for (final OcrLine line in lines) {
      if (_intOf(line.text) != null && line.box.centreY < firstNumber) {
        firstNumber = line.box.centreY;
      }
    }

    double bottom = double.negativeInfinity;
    for (final OcrLine line in lines) {
      if (line.box.centreY >= firstNumber) continue;
      final String text = line.text.toLowerCase();
      if (_headerWords.any(text.contains) && line.box.bottom > bottom) {
        bottom = line.box.bottom;
      }
    }
    return bottom;
  }

  /// One centre per row, clustered from the cells alone.
  static List<double> _rowCentres(List<OcrLine> numbers) {
    final List<OcrLine> sorted = <OcrLine>[...numbers]
      ..sort((OcrLine a, OcrLine b) => a.box.centreY.compareTo(b.box.centreY));
    if (sorted.isEmpty) return const <double>[];

    final double tolerance = _medianHeight(sorted) * 0.6;
    final List<double> centres = <double>[];
    final List<double> current = <double>[];
    for (final OcrLine line in sorted) {
      if (current.isEmpty || line.box.centreY - current.last <= tolerance) {
        current.add(line.box.centreY);
      } else {
        centres.add(
          current.reduce((double a, double b) => a + b) / current.length,
        );
        current
          ..clear()
          ..add(line.box.centreY);
      }
    }
    if (current.isNotEmpty) {
      centres.add(
        current.reduce((double a, double b) => a + b) / current.length,
      );
    }
    return centres;
  }

  /// Worked out once over every cell rather than per row, which is the point:
  /// a row missing a cell cannot say which of its own columns are which, but
  /// the table can say it for them.
  static List<double> _columnCentres(List<OcrLine> numbers) {
    if (numbers.isEmpty) return const <double>[];
    final List<double> xs = <double>[
      for (final OcrLine l in numbers) l.box.centreX,
    ]..sort();

    final List<double> widths = <double>[
      for (final OcrLine l in numbers) l.box.width,
    ]..sort();
    final double tolerance = widths[widths.length ~/ 2] * 2;

    final List<List<double>> groups = <List<double>>[
      <double>[xs.first]
    ];
    for (int i = 1; i < xs.length; i++) {
      if (xs[i] - groups.last.last <= tolerance) {
        groups.last.add(xs[i]);
      } else {
        groups.add(<double>[xs[i]]);
      }
    }

    final List<double> centres = <double>[
      for (final List<double> g in groups)
        g.reduce((double a, double b) => a + b) / g.length,
    ];
    // A wrapped course name can end in digits of its own — a term stamp broken
    // across lines leaves a bare `27` in the name column — so the numbers are
    // taken from the right.
    return centres.length <= 3
        ? centres
        : centres.sublist(centres.length - 3);
  }

  /// The digits in a cell, whatever rule was glued to them.
  static int? _intOf(String text) {
    final RegExpMatch? match = _int.firstMatch(text.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static double _medianHeight(List<OcrLine> lines) {
    final List<double> heights = <double>[
      for (final OcrLine l in lines) l.box.height,
    ]..sort();
    return heights[heights.length ~/ 2];
  }

  static TotalsRow? _rowFrom({
    required List<OcrLine> band,
    required List<OcrLine> cells,
    required List<double> columns,
  }) {
    final List<OcrLine> digits = <OcrLine>[
      for (final OcrLine l in cells)
        if (_intOf(l.text) != null) l,
    ]..sort((OcrLine a, OcrLine b) => a.box.centreX.compareTo(b.box.centreX));

    int? total;
    int? held;
    int? attended;
    final List<OcrLine> placed = <OcrLine>[];

    if (columns.length == 3) {
      final double reach = _reach(columns);
      for (final OcrLine cell in digits) {
        final int column = _nearest(columns, cell.box.centreX, reach);
        if (column < 0) continue;
        placed.add(cell);
        final int value = _intOf(cell.text)!;
        switch (column) {
          case 0:
            total = value;
          case 1:
            held = value;
          case 2:
            attended = value;
        }
      }
    } else if (digits.length >= 3) {
      placed.addAll(digits.sublist(digits.length - 3));
      total = _intOf(placed[0].text);
      held = _intOf(placed[1].text);
      attended = _intOf(placed[2].text);
    }

    final double? printed = _printedPercent(band);

    // The page shows its working, so one unread cell out of held and attended
    // is not lost — the other one and the percentage give it back. Checked
    // against the printed figure afterwards rather than trusted.
    if (printed != null) {
      if (attended == null && held != null) {
        attended = (held * printed / 100).round();
      } else if (held == null && attended != null && printed > 0) {
        held = (attended * 100 / printed).round();
      }
      if (held != null &&
          attended != null &&
          (held == 0
              ? attended != 0
              : (attended * 100 / held - printed).abs() >= 0.55)) {
        held = null;
        attended = null;
      }
    }

    // A dash with no digits beside it means the term has not started, and the
    // figures stay editable on the subject. A dash *with* digits is ambiguous —
    // an unread cell and a printed zero look the same here — so it is refused.
    if (held == null || attended == null) {
      final bool blank = digits.isEmpty &&
          cells.any((OcrLine l) => _isBlankCell(l.text));
      if (!blank) return null;
      total = 0;
      held = 0;
      attended = 0;
    }

    final List<OcrLine> nameLines = <OcrLine>[
      for (final OcrLine l in band)
        if (!_percent.hasMatch(l.text.trim()) &&
            !_blankCell.hasMatch(l.text.trim()) &&
            !_isFooter(l.text) &&
            _intOf(l.text) == null)
          l,
    ]..sort((OcrLine a, OcrLine b) {
        final int byRow = a.box.centreY.compareTo(b.box.centreY);
        return byRow != 0 ? byRow : a.box.centreX.compareTo(b.box.centreX);
      });

    final String name = cleanName(
      nameLines.map((OcrLine l) => l.text).join(' '),
    );
    if (name.isEmpty) return null;

    return TotalsRow(
      subject: name,
      expectedTotal: total,
      held: held,
      attended: attended,
      printedPercent: printed,
      namesTwoCourses: _stampInside.hasMatch(name),
    );
  }

  static double? _printedPercent(List<OcrLine> band) {
    double? printed;
    for (final OcrLine line in band) {
      final RegExpMatch? match = _percent.firstMatch(line.text.trim());
      if (match != null) {
        printed = double.tryParse(match.group(1)!.replaceAll(',', '.'));
      }
    }
    return printed;
  }

  /// How far from a column's centre a cell may sit and still belong to it.
  static double _reach(List<double> columns) {
    double gap = double.infinity;
    for (int i = 1; i < columns.length; i++) {
      final double between = columns[i] - columns[i - 1];
      if (between < gap) gap = between;
    }
    return gap / 2;
  }

  static int _nearest(List<double> columns, double x, double reach) {
    int best = -1;
    double closest = reach;
    for (int i = 0; i < columns.length; i++) {
      final double distance = (columns[i] - x).abs();
      if (distance < closest) {
        closest = distance;
        best = i;
      }
    }
    return best;
  }

  /// The course name with the portal's term stamp taken off.
  static String cleanName(String raw) {
    final String joined = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String stripped = joined.replaceFirst(_termStamp, '');
    final String cleaned =
        stripped.replaceAll(RegExp(r'[_\s\-,;:]+$'), '').trim();
    return cleaned.isEmpty ? joined : cleaned;
  }

  static int? _footerValue(
    List<OcrLine> lines,
    RegExp pattern, {
    RegExp? skip,
  }) {
    for (final OcrLine line in lines) {
      final String text = line.text;
      if (skip != null && skip.hasMatch(text)) continue;
      final RegExpMatch? match = pattern.firstMatch(text);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }
}
