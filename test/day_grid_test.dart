import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/domain/day_grid.dart';

/// 9:00–17:00 on 50-minute blocks: nine whole blocks and a 30-minute tail.
const DayGrid _grid = DayGrid(
  dayStartMinutes: 9 * 60,
  dayEndMinutes: 17 * 60,
  blockMinutes: 50,
);

/// The real timetable this was built against: eight blocks and a 40-minute last.
const DayGrid _shortLast = DayGrid(
  dayStartMinutes: 9 * 60 + 10,
  dayEndMinutes: 16 * 60 + 30,
  blockMinutes: 50,
);

/// The same day with a 40-minute break after the fourth block.
const DayGrid _withBreak = DayGrid(
  dayStartMinutes: 9 * 60,
  dayEndMinutes: 17 * 60,
  blockMinutes: 50,
  breakAfterBlock: 4,
  breakMinutes: 40,
);

void main() {
  group('shape of the day', () {
    test('counts the short final block and reports its length', () {
      expect(_grid.blockCount, 10);
      expect(_grid.tailMinutes, 30);
      expect(_grid.isConfigured, isTrue);
    });

    test('a day that divides evenly has no tail', () {
      const DayGrid even = DayGrid(
        dayStartMinutes: 9 * 60,
        dayEndMinutes: 17 * 60,
        blockMinutes: 60,
      );
      expect(even.blockCount, 8);
      expect(even.tailMinutes, 0);
    });

    test('is unconfigured without a block length', () {
      const DayGrid none = DayGrid(
        dayStartMinutes: 9 * 60,
        dayEndMinutes: 17 * 60,
        blockMinutes: 0,
      );
      expect(none.isConfigured, isFalse);
      expect(none.blockCount, 0);
      expect(DayGrid.none.isConfigured, isFalse);
    });

    test('is unconfigured when the day ends before it starts', () {
      const DayGrid backwards = DayGrid(
        dayStartMinutes: 17 * 60,
        dayEndMinutes: 9 * 60,
        blockMinutes: 50,
      );
      expect(backwards.isConfigured, isFalse);
      expect(backwards.tailMinutes, 0);
    });

    test('blocks run back to back from the start of the day', () {
      expect(_grid.startOf(0), 9 * 60);
      expect(_grid.endOf(0), 9 * 60 + 50);
      expect(_grid.startOf(1), _grid.endOf(0));
      expect(_grid.startOf(8), 9 * 60 + 8 * 50);
    });

    test('the last block stops at the end of the day', () {
      expect(_grid.startOf(9), 16 * 60 + 30);
      expect(_grid.endOf(9), 17 * 60);
      expect(_grid.lengthOf(9), 30);
      expect(_grid.lengthOf(0), 50);
    });
  });

  group('a shortened last period', () {
    test('gets a block instead of falling off the end of the day', () {
      // Counting whole blocks only left this class outside the grid entirely.
      expect(_shortLast.blockCount, 9);
      expect(_shortLast.startOf(8), 15 * 60 + 50);
      expect(_shortLast.lengthOf(8), 40);
    });

    test('a class starting in it lands on the grid, aligned', () {
      expect(_shortLast.indexOf(15 * 60 + 50), 8);
      expect(_shortLast.isAligned(15 * 60 + 50), isTrue);
    });

    test('a class after the day has ended still has no block', () {
      expect(_shortLast.indexOf(16 * 60 + 30), isNull);
    });
  });

  group('a break in the middle of the day', () {
    test('pushes the afternoon back by its own length', () {
      expect(_withBreak.hasBreak, isTrue);
      expect(_withBreak.breakStartMinutes, 12 * 60 + 20);
      expect(_withBreak.breakEndMinutes, 13 * 60);
      expect(_withBreak.startOf(3), 11 * 60 + 30);
      expect(_withBreak.endOf(3), 12 * 60 + 20);
      expect(_withBreak.startOf(4), 13 * 60);
    });

    test('shortens the day by one block and leaves a tail', () {
      expect(_withBreak.blockCount, 9);
      expect(_withBreak.tailMinutes, 40);
      expect(_withBreak.startOf(8), 16 * 60 + 20);
      expect(_withBreak.endOf(8), 17 * 60);
    });

    test('a class inside the break sits on no block at all', () {
      expect(_withBreak.indexOf(12 * 60 + 20), isNull);
      expect(_withBreak.indexOf(12 * 60 + 40), isNull);
      expect(_withBreak.isAligned(12 * 60 + 20), isFalse);
    });

    test('the afternoon is still aligned, on its own rhythm', () {
      expect(_withBreak.indexOf(13 * 60), 4);
      expect(_withBreak.isAligned(13 * 60), isTrue);
      // 12:50 would have been a boundary without the break.
      expect(_withBreak.isAligned(12 * 60 + 50), isFalse);
    });

    test('is dropped when the day is later shortened past it', () {
      const DayGrid shortened = DayGrid(
        dayStartMinutes: 9 * 60,
        dayEndMinutes: 11 * 60,
        blockMinutes: 50,
        breakAfterBlock: 4,
        breakMinutes: 40,
      );
      expect(shortened.hasBreak, isFalse);
      expect(shortened.blockCount, 3);
      expect(shortened.startOf(0), 9 * 60);
    });

    test('a break needs a block on both sides of it', () {
      expect(_grid.maxBreakAfterBlock, 8);
      expect(DayGrid.none.maxBreakAfterBlock, 0);
    });
  });

  group('a class is a whole number of blocks', () {
    test('a lecture is one and a double lab is two', () {
      expect(_grid.blocksFor(50), 1);
      expect(_grid.blocksFor(100), 2);
    });

    test('a hand-typed near miss still reads as the block it meant', () {
      expect(_grid.blocksFor(95), 2);
      expect(_grid.blocksFor(105), 2);
    });

    test('never less than one block, whatever the length', () {
      expect(_grid.blocksFor(0), 1);
      expect(_grid.blocksFor(5), 1);
    });

    test('snapping rounds to the nearest block boundary', () {
      expect(_grid.snapDuration(95), 100);
      expect(_grid.snapDuration(50), 50);
    });

    test('an unconfigured grid leaves lengths alone', () {
      expect(DayGrid.none.snapDuration(95), 95);
      expect(DayGrid.none.blocksFor(95), 1);
    });

    test('only exact multiples count as whole blocks', () {
      expect(_grid.isWholeBlocks(100), isTrue);
      expect(_grid.isWholeBlocks(95), isFalse);
      expect(_grid.isWholeBlocks(0), isFalse);
      expect(DayGrid.none.isWholeBlocks(50), isFalse);
    });
  });

  group('placing a class on the grid', () {
    test('a start time lands in the block that contains it', () {
      expect(_grid.indexOf(9 * 60), 0);
      expect(_grid.indexOf(9 * 60 + 49), 0);
      expect(_grid.indexOf(9 * 60 + 50), 1);
    });

    test('a class outside the teaching day has no block', () {
      expect(_grid.indexOf(8 * 60), isNull);
      expect(_grid.indexOf(17 * 60), isNull);
    });

    test('alignment separates grid classes from ones typed by hand', () {
      expect(_grid.isAligned(9 * 60 + 50), isTrue);
      expect(_grid.isAligned(9 * 60 + 30), isFalse);
      expect(_grid.isAligned(8 * 60), isFalse);
    });
  });
}
