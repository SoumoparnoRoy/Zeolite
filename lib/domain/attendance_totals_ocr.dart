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
  final int expectedTotal;
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
  bool get isOrdered => attended <= held && held <= expectedTotal;

  bool get isTrustworthy => percentAgrees && isOrdered && !namesTwoCourses;
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

  int get totalSum =>
      rows.fold<int>(0, (int sum, TotalsRow r) => sum + r.expectedTotal);

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
  static final RegExp _stampInside = RegExp(
    r'[_\s]' '$_term' r'[_\s]*\d{4}\s*-?\s*\d{0,4}[_\s]+\S',
    caseSensitive: false,
  );

  static final RegExp _footerTotal =
      RegExp(r'total\s*sessions?\s*[:\-]?\s*(\d{1,5})', caseSensitive: false);
  static final RegExp _footerAttended = RegExp(
    r'total\s*attended\s*sessions?\s*[:\-]?\s*(\d{1,5})',
    caseSensitive: false,
  );

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

  static AttendanceTotals? read(List<OcrLine> lines) {
    if (!looksLikeTotals(lines)) return null;

    final double headerBottom = _headerBottom(lines);
    final List<OcrLine> body = <OcrLine>[
      for (final OcrLine line in lines)
        if (line.box.centreY > headerBottom) line,
    ];

    final List<double> rowCentres = _rowCentres(body);
    if (rowCentres.length < 2) return null;

    final List<TotalsRow> rows = <TotalsRow>[];
    for (int i = 0; i < rowCentres.length; i++) {
      final double top = i == 0
          ? double.negativeInfinity
          : (rowCentres[i - 1] + rowCentres[i]) / 2;
      final double bottom = i == rowCentres.length - 1
          ? double.infinity
          : (rowCentres[i] + rowCentres[i + 1]) / 2;
      final TotalsRow? row = _rowFrom(<OcrLine>[
        for (final OcrLine l in body)
          if (l.box.centreY > top && l.box.centreY <= bottom) l,
      ]);
      if (row != null) rows.add(row);
    }
    if (rows.isEmpty) return null;

    final AttendanceTotals read = AttendanceTotals(
      rows: rows,
      printedTotal: _footerValue(lines, _footerTotal, skip: _footerAttended),
      printedAttended: _footerValue(lines, _footerAttended),
    );

    // A page's own total cannot be smaller than the rows it is made of, so a
    // footer below the sum was misread rather than contradicted — the number
    // sits in a coloured band and loses digits easily. Dropping it says
    // nothing, which beats claiming the page disagrees when it does not.
    return AttendanceTotals(
      rows: rows,
      printedTotal: (read.printedTotal ?? read.totalSum) < read.totalSum
          ? null
          : read.printedTotal,
      printedAttended:
          (read.printedAttended ?? read.attendedSum) < read.attendedSum
              ? null
              : read.printedAttended,
    );
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

  /// One centre per row, clustered from the number cells alone.
  static List<double> _rowCentres(List<OcrLine> body) {
    final List<OcrLine> numbers = <OcrLine>[
      for (final OcrLine l in body)
        if (_intOf(l.text) != null) l,
    ]..sort((OcrLine a, OcrLine b) => a.box.centreY.compareTo(b.box.centreY));
    if (numbers.isEmpty) return const <double>[];

    final double tolerance = _medianHeight(numbers) * 0.6;
    final List<double> centres = <double>[];
    final List<double> current = <double>[];
    for (final OcrLine line in numbers) {
      if (current.isEmpty || line.box.centreY - current.last <= tolerance) {
        current.add(line.box.centreY);
      } else {
        centres.add(current.reduce((double a, double b) => a + b) /
            current.length);
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

  /// Total, marked and attended are the last three numbers across the row.
  ///
  /// Taken from the right rather than the left because a wrapped course name
  /// can end in digits of its own — a term stamp broken across lines leaves a
  /// bare `27` sitting in the name column.
  static TotalsRow? _rowFrom(List<OcrLine> band) {
    final List<OcrLine> numbers = <OcrLine>[
      for (final OcrLine l in band)
        if (_intOf(l.text) != null) l,
    ]..sort((OcrLine a, OcrLine b) => a.box.centreX.compareTo(b.box.centreX));
    if (numbers.length < 3) return null;

    final List<OcrLine> cells = numbers.sublist(numbers.length - 3);
    final int total = _intOf(cells[0].text)!;
    final int held = _intOf(cells[1].text)!;
    final int attended = _intOf(cells[2].text)!;

    double? printed;
    for (final OcrLine line in band) {
      final RegExpMatch? match = _percent.firstMatch(line.text.trim());
      if (match != null) {
        printed = double.tryParse(match.group(1)!.replaceAll(',', '.'));
      }
    }

    final List<OcrLine> nameLines = <OcrLine>[
      for (final OcrLine l in band)
        if (!cells.contains(l) &&
            !_percent.hasMatch(l.text.trim()) &&
            !_blankCell.hasMatch(l.text.trim()))
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
