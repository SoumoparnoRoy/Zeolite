import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/domain/grid_lines.dart';

/// A blank page a test draws its own table on. Bitmaps rather than anything
/// captured off a real sheet, so no timetable belonging to anyone is in here.
class Page {
  Page(this.width, this.height)
      : _px = Uint8List(width * height)..fillRange(0, width * height, 255);

  final int width;
  final int height;
  final Uint8List _px;

  void down(int x, int from, int to) {
    for (int y = from; y < to; y++) {
      for (int t = 0; t < 2; t++) {
        _px[y * width + x + t] = 0;
      }
    }
  }

  void across(int y, int from, int to) {
    for (int x = from; x < to; x++) {
      for (int t = 0; t < 2; t++) {
        _px[(y + t) * width + x] = 0;
      }
    }
  }

  void mark(int x, int y, {int w = 40, int h = 8}) {
    for (int j = y; j < y + h; j++) {
      for (int i = x; i < x + w; i++) {
        _px[j * width + i] = 30;
      }
    }
  }

  InkMap get ink => InkMap.from(_px, width, height);
}

const List<int> _cols = <int>[50, 150, 250, 350, 450, 550, 650];
const List<int> _rows = <int>[40, 120, 200, 280, 360, 440];

Page ruled(
    {Set<(int, int)> noRight = const <(int, int)>{},
    Set<(int, int)> noBelow = const <(int, int)>{}}) {
  final Page p = Page(700, 500);
  for (int c = 0; c < _cols.length; c++) {
    for (int r = 0; r + 1 < _rows.length; r++) {
      final bool outer = c == 0 || c == _cols.length - 1;
      if (!outer && noRight.contains((r, c - 1))) continue;
      p.down(_cols[c], _rows[r], _rows[r + 1]);
    }
  }
  for (int r = 0; r < _rows.length; r++) {
    for (int c = 0; c + 1 < _cols.length; c++) {
      final bool outer = r == 0 || r == _rows.length - 1;
      if (!outer && noBelow.contains((r - 1, c))) continue;
      p.across(_rows[r], _cols[c], _cols[c + 1]);
    }
  }
  return p;
}

void main() {
  test('a ruled table gives back its own lines', () {
    final TableLattice grid = GridLines.read(ruled().ink)!;

    expect(grid.columns, 6);
    expect(grid.rows, 5);
    for (int i = 0; i < _cols.length; i++) {
      expect(grid.xs[i], closeTo(_cols[i], 2));
    }
    for (int i = 0; i < _rows.length; i++) {
      expect(grid.ys[i], closeTo(_rows[i], 2));
    }
  });

  test('a card drawn inside one cell is not a rule', () {
    // A card's edges are as straight as the table's, and at a tenth-of-the-page
    // span threshold the weekly sheet took them for period boundaries.
    final Page p = ruled();
    for (int r = 0; r + 1 < _rows.length; r++) {
      for (int c = 0; c + 1 < _cols.length; c++) {
        p.down(_cols[c] + 12, _rows[r] + 8, _rows[r + 1] - 8);
        p.down(_cols[c + 1] - 12, _rows[r] + 8, _rows[r + 1] - 8);
        p.across(_rows[r] + 8, _cols[c] + 12, _cols[c + 1] - 12);
        p.across(_rows[r + 1] - 8, _cols[c] + 12, _cols[c + 1] - 12);
      }
    }

    final TableLattice grid = GridLines.read(p.ink)!;
    expect(grid.columns, 6);
    expect(grid.rows, 5);
  });

  test('a divider left out of one row is a merged cell there and nowhere else',
      () {
    final TableLattice grid =
        GridLines.read(ruled(noRight: <(int, int)>{(1, 1)}).ink)!;

    expect(grid.mergesRight(1, 1), isTrue);
    expect(grid.mergesRight(0, 1), isFalse);
    expect(grid.mergesRight(2, 1), isFalse);
    expect(grid.mergesRight(1, 0), isFalse);
    expect(grid.mergesRight(1, 2), isFalse);
  });

  test('a column running the height of the table merges down every row', () {
    // The packed sheet's Lunch column, read structurally, not off a word list.
    final TableLattice grid = GridLines.read(
      ruled(noBelow: <(int, int)>{(0, 3), (1, 3), (2, 3)}).ink,
    )!;

    for (int r = 0; r < 3; r++) {
      expect(grid.mergesBelow(r, 3), isTrue, reason: 'row $r');
      expect(grid.mergesBelow(r, 2), isFalse, reason: 'row $r');
    }
  });

  test('a legend ruled under the table is not part of it', () {
    // Widening the last band to a sheet's true bottom read the legend as six
    // more classes. It draws lines, but not the table's dividers.
    final Page p = ruled();
    p.across(470, 50, 650);
    p.across(500 - 3, 50, 650);
    p.mark(70, 478);
    p.mark(300, 478);

    final TableLattice grid = GridLines.read(p.ink)!;
    expect(grid.rows, 5);
    expect(grid.ys.last, closeTo(440, 2));
  });

  test('an edge the crop cut off is taken from the image bound', () {
    // A cropped screenshot: the period headers sit above the first rule.
    final Page p = Page(700, 500);
    for (int c = 0; c < _cols.length; c++) {
      p.down(_cols[c], 0, _rows.last);
    }
    for (int r = 1; r < _rows.length; r++) {
      p.across(_rows[r], _cols.first, _cols.last);
    }
    for (int c = 0; c + 1 < _cols.length; c++) {
      p.mark(_cols[c] + 30, 14);
    }

    final TableLattice grid = GridLines.read(p.ink)!;
    expect(grid.ys.first, 0);
    expect(grid.rows, 5);
  });

  test('a page with no table on it reads as none', () {
    final Page p = Page(700, 500);
    for (int i = 0; i < 12; i++) {
      p.mark(60 + (i % 4) * 150, 60 + (i ~/ 4) * 90);
    }

    expect(GridLines.read(p.ink), isNull);
  });
}
