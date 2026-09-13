import 'dart:typed_data';

/// A page reduced to ink and paper.
///
/// Thresholded against a local mean rather than one cutoff for the whole page,
/// which a photographed or unevenly lit sheet never has.
///
/// Plain Dart like [OcrBox] next door, so the geometry can be tested against
/// bitmaps a test draws itself with no image decoder and no device.
class InkMap {
  InkMap._(this.width, this.height, this._ink);

  /// The side of the neighbourhood each pixel is judged against.
  static const int _window = 21;

  /// How much darker than its neighbourhood a pixel has to be. Without it a
  /// flat area of paper comes out half ink from its own noise.
  static const int _offset = 5;

  /// One byte of grey per pixel, row-major.
  factory InkMap.from(Uint8List grey, int width, int height) {
    final int stride = width + 1;
    final Uint32List sum = Uint32List(stride * (height + 1));
    for (int y = 0; y < height; y++) {
      final int above = y * stride;
      final int here = above + stride;
      int run = 0;
      for (int x = 0; x < width; x++) {
        run += grey[y * width + x];
        sum[here + x + 1] = sum[above + x + 1] + run;
      }
    }

    const int r = _window ~/ 2;
    final Uint8List ink = Uint8List(width * height);
    for (int y = 0; y < height; y++) {
      final int y0 = y < r ? 0 : y - r;
      final int y1 = y + r + 1 > height ? height : y + r + 1;
      for (int x = 0; x < width; x++) {
        final int x0 = x < r ? 0 : x - r;
        final int x1 = x + r + 1 > width ? width : x + r + 1;
        final int total = sum[y1 * stride + x1] -
            sum[y0 * stride + x1] -
            sum[y1 * stride + x0] +
            sum[y0 * stride + x0];
        final int n = (y1 - y0) * (x1 - x0);
        // grey < mean - offset, kept in integers.
        if (grey[y * width + x] * n < total - _offset * n) {
          ink[y * width + x] = 1;
        }
      }
    }
    return InkMap._(width, height, ink);
  }

  final int width;
  final int height;
  final Uint8List _ink;

  bool at(int x, int y) => _ink[y * width + x] != 0;
}

/// A table found on a page: where it draws its lines, and which of its cells
/// run together.
class TableLattice {
  const TableLattice({
    required this.xs,
    required this.ys,
    required this.dividedRight,
    required this.dividedBelow,
  });

  /// Vertical rules, left to right, and horizontal rules, top to bottom. Both
  /// include the table's own outside edges.
  final List<int> xs;
  final List<int> ys;

  /// Whether the divider on a cell's right, and below it, is actually drawn.
  /// Indexed `[row][column]`; the table's outer edges are not included, so
  /// both are one shorter than the cell count along that axis.
  final List<List<bool>> dividedRight;
  final List<List<bool>> dividedBelow;

  int get columns => xs.length - 1;
  int get rows => ys.length - 1;

  /// A cell that runs on into the next column — a lab drawn across two
  /// periods, with the divider left out of that row alone.
  bool mergesRight(int row, int column) =>
      column < columns - 1 && !dividedRight[row][column];

  /// A cell that runs on into the next row.
  bool mergesBelow(int row, int column) =>
      row < rows - 1 && !dividedBelow[row][column];

  /// The same table in the coordinates of an image [by] times the size, for
  /// putting a lattice found on a working copy back onto the original.
  TableLattice scaled(double by) => TableLattice(
        xs: <int>[for (final int x in xs) (x * by).round()],
        ys: <int>[for (final int y in ys) (y * by).round()],
        dividedRight: dividedRight,
        dividedBelow: dividedBelow,
      );
}

/// Reads a table's own ruling off the page.
///
/// Two passes, and the second cannot be folded into the first. Deciding that a
/// line is part of the table needs it to run most of the way across, which is
/// what separates a rule from the edge of a coloured card sitting in one cell.
/// That same length test erases a divider drawn down one row only, which is
/// exactly the evidence a merged cell leaves behind. So the lattice is found
/// with the long test and the merges are then measured against the raw ink.
class GridLines {
  /// How far along its axis a line must run to count as part of the table.
  /// A tenth admits card edges; at three tenths they are gone and no real rule
  /// on any sheet measured is lost.
  static const double _span = 0.30;

  /// Two rules nearer than this are one thick rule.
  static const int _apart = 8;

  /// The shortest run worth calling a line on a small image.
  static const int _shortest = 30;

  /// Ends of a divider are ignored when judging whether it is drawn: cell text
  /// crowds them, and a rule that stops short still divides.
  static const double _inset = 0.12;

  /// A rule is rarely exactly where the projection put it.
  static const int _tolerance = 3;

  /// How much of a divider has to be inked before it counts as drawn. Low on
  /// purpose — reading a divider that is there as missing fuses two real
  /// classes into one, which is worse than missing a merge.
  static const double _drawn = 0.35;

  /// The share of its dividers a band needs before it is table rather than the
  /// title block or the legend printed under one.
  static const double _bodyShare = 0.75;

  /// A margin outside the outermost rule this deep, relative to the usual
  /// band, is a row whose far edge was cropped away rather than a white border.
  static const double _marginShare = 0.25;

  /// Returns null when the page draws nothing that looks like a table.
  static TableLattice? read(InkMap ink) {
    final List<int> xs = _rules(ink, vertical: true);
    final List<int> ys = _rules(ink, vertical: false);
    if (xs.length < 3 || ys.length < 2) return null;

    final List<int> bands =
        _body(ink, xs, _edged(ink, ys, xs, vertical: false));
    if (bands.length < 2) return null;
    final List<int> columns = _edged(ink, xs, bands, vertical: true);

    return TableLattice(
      xs: columns,
      ys: bands,
      dividedRight: <List<bool>>[
        for (int r = 0; r + 1 < bands.length; r++)
          <bool>[
            for (int c = 1; c + 1 < columns.length; c++)
              _inked(ink, columns[c], bands[r], bands[r + 1], vertical: true),
          ],
      ],
      dividedBelow: <List<bool>>[
        for (int r = 1; r + 1 < bands.length; r++)
          <bool>[
            for (int c = 0; c + 1 < columns.length; c++)
              _inked(ink, bands[r], columns[c], columns[c + 1],
                  vertical: false),
          ],
      ],
    );
  }

  /// Every position whose ink runs far enough along the perpendicular axis to
  /// be part of the table rather than of one cell.
  static List<int> _rules(InkMap ink, {required bool vertical}) {
    final int along = vertical ? ink.height : ink.width;
    final int across = vertical ? ink.width : ink.height;
    final int least = _max(_shortest, (along * _span * 0.8).round());

    final Int32List support = Int32List(across);
    for (int a = 0; a < across; a++) {
      int run = 0;
      int total = 0;
      for (int b = 0; b < along; b++) {
        if (vertical ? ink.at(a, b) : ink.at(b, a)) {
          run++;
          continue;
        }
        if (run >= least) total += run;
        run = 0;
      }
      if (run >= least) total += run;
      support[a] = total;
    }
    return _grouped(support, (along * _span).round());
  }

  static List<int> _grouped(Int32List support, int floor) {
    final List<int> out = <int>[];
    int? from;
    int? last;
    for (int i = 0; i < support.length; i++) {
      if (support[i] <= floor) continue;
      if (last != null && i - last > _apart) {
        out.add((from! + last) ~/ 2);
        from = null;
      }
      from ??= i;
      last = i;
    }
    if (from != null) out.add((from + last!) ~/ 2);
    return out;
  }

  /// The run of bands that is the table itself.
  ///
  /// A title block above the grid and a legend below it both draw lines, and
  /// neither carries the table's full set of dividers. So the table is the
  /// longest stretch of neighbouring bands where nearly every divider is there
  /// — which drops both without guessing at a depth.
  static List<int> _body(InkMap ink, List<int> xs, List<int> ys) {
    if (xs.length < 3) return ys;
    bool full(int from, int to) {
      int drawn = 0;
      for (int c = 1; c + 1 < xs.length; c++) {
        if (_inked(ink, xs[c], from, to, vertical: true)) drawn++;
      }
      return drawn / (xs.length - 2) >= _bodyShare;
    }

    int bestFrom = 0, bestTo = 0, from = 0, run = 0;
    for (int i = 0; i + 1 < ys.length; i++) {
      if (full(ys[i], ys[i + 1])) {
        if (run == 0) from = i;
        run++;
        if (run > bestTo - bestFrom) {
          bestFrom = from;
          bestTo = from + run;
        }
        continue;
      }
      run = 0;
    }
    return bestTo > bestFrom ? ys.sublist(bestFrom, bestTo + 1) : <int>[];
  }

  /// Puts back an outer edge the image itself cut off.
  ///
  /// A cropped screenshot loses the border on whichever side it was cut, and
  /// the row or column against it then has nothing closing it — the class-wise
  /// sheet's period headers sit above its first rule for exactly this reason.
  /// The image bound stands in, but only where the margin is deep enough to
  /// hold a row and has something printed in it.
  static List<int> _edged(
    InkMap ink,
    List<int> rules,
    List<int> across, {
    required bool vertical,
  }) {
    if (rules.length < 2 || across.length < 2) return rules;
    final int bound = vertical ? ink.width : ink.height;
    final List<int> pitch = <int>[
      for (int i = 1; i < rules.length; i++) rules[i] - rules[i - 1],
    ]..sort();
    final int usual = pitch[pitch.length ~/ 2];

    final List<int> out = <int>[...rules];
    if (_holds(ink, 0, rules.first, across, vertical: vertical) &&
        rules.first >= usual * _marginShare) {
      out.insert(0, 0);
    }
    if (_holds(ink, rules.last, bound - 1, across, vertical: vertical) &&
        bound - 1 - rules.last >= usual * _marginShare) {
      out.add(bound - 1);
    }
    return out;
  }

  /// Whether anything at all is printed in a margin.
  ///
  /// Clear of the rule bounding it, or a rule thick enough to have a second
  /// row of pixels reads as content and every table gains an outer edge.
  static bool _holds(
    InkMap ink,
    int from,
    int to,
    List<int> across, {
    required bool vertical,
  }) {
    for (int p = from + _tolerance; p < to - _tolerance; p++) {
      for (int q = across.first; q < across.last; q++) {
        if (vertical ? ink.at(p, q) : ink.at(q, p)) return true;
      }
    }
    return false;
  }

  /// Whether a divider is drawn between [from] and [to] along the rule at [at].
  ///
  /// Measured on the raw ink, never on the length-filtered pass that found the
  /// rules: that filter is longer than a single band, so every divider spanning
  /// one row would read as absent.
  static bool _inked(
    InkMap ink,
    int at,
    int from,
    int to, {
    required bool vertical,
  }) {
    final int inset = ((to - from) * _inset).round();
    final int a = from + inset;
    final int b = to - inset;
    if (b - a < 4) return true;

    int hit = 0;
    for (int i = a; i < b; i++) {
      for (int t = -_tolerance; t <= _tolerance; t++) {
        final int p = at + t;
        final bool inside = vertical
            ? p >= 0 && p < ink.width && i < ink.height
            : p >= 0 && p < ink.height && i < ink.width;
        if (!inside) continue;
        if (vertical ? ink.at(p, i) : ink.at(i, p)) {
          hit++;
          break;
        }
      }
    }
    return hit / (b - a) >= _drawn;
  }

  static int _max(int a, int b) => a > b ? a : b;
}
