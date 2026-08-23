import 'package:flutter/foundation.dart';

/// The day divided into uniform blocks of one lecture each.
///
/// Three numbers rather than a table of named periods, because a period-based
/// timetable has no arbitrary segments: every class is a whole number of blocks,
/// a double lab is two of them, and a free period is a block with nothing in it.
/// The shape of the day follows from where it starts, where it ends and how long
/// one block runs.
///
/// Classes still store real start and end minutes, so the schedule engine, the
/// stats and old backups are untouched. This is a lens, not a second source of
/// truth.
@immutable
class DayGrid {
  const DayGrid({
    required this.dayStartMinutes,
    required this.dayEndMinutes,
    required this.blockMinutes,
    this.breakAfterBlock = 0,
    this.breakMinutes = 0,
  });

  /// The day has not been divided up, which is where every install starts.
  static const DayGrid none = DayGrid(
    dayStartMinutes: 0,
    dayEndMinutes: 0,
    blockMinutes: 0,
  );

  final int dayStartMinutes;
  final int dayEndMinutes;
  final int blockMinutes;

  /// Which block the break follows, counting from one. Zero means no break.
  ///
  /// Anchored to a block rather than to a clock time so the break can only ever
  /// fall on a boundary — the arithmetic below never has to cope with a break
  /// starting halfway through a lecture, and "after 4th period" is how the
  /// timetable describes it anyway.
  final int breakAfterBlock;

  final int breakMinutes;

  bool get _hasBreak =>
      breakMinutes > 0 && breakAfterBlock > 0 && blockMinutes > 0;

  int get _span => dayEndMinutes - dayStartMinutes;

  /// Blocks sitting before the break. A break configured past the end of the
  /// day is dropped rather than pushing every later block off the clock, which
  /// can happen when the day is shortened after the break was set.
  int get _beforeBreak {
    if (!_hasBreak || _span <= 0) return 0;
    final int fits = _span ~/ blockMinutes;
    return breakAfterBlock < fits ? breakAfterBlock : 0;
  }

  /// Whether a break is actually in effect, which [breakMinutes] alone does not
  /// answer.
  bool get hasBreak => _beforeBreak > 0;

  int get breakStartMinutes => dayStartMinutes + _beforeBreak * blockMinutes;

  int get breakEndMinutes =>
      breakStartMinutes + (_beforeBreak > 0 ? breakMinutes : 0);

  int get _afterBreakSpan => dayEndMinutes - breakEndMinutes;

  /// Every block in the day, including a short final one where the day does not
  /// divide evenly.
  ///
  /// The tail is counted rather than discarded because a real timetable does put
  /// a class in it — a shortened last period is common — and a block that does
  /// not exist is a class that cannot be drawn.
  int get blockCount {
    if (blockMinutes <= 0 || _span <= 0) return 0;
    final int after = _afterBreakSpan;
    if (after <= 0) return _beforeBreak;
    return _beforeBreak +
        (after ~/ blockMinutes) +
        (after % blockMinutes > 0 ? 1 : 0);
  }

  bool get isConfigured => blockCount > 0;

  /// Length of the short final block, or zero when the day divides evenly.
  /// Surfaced in Settings so a day that does not come out round says so.
  int get tailMinutes {
    if (blockMinutes <= 0) return 0;
    final int after = _afterBreakSpan;
    return after <= 0 ? 0 : after % blockMinutes;
  }

  /// The largest [breakAfterBlock] that still leaves a block after the break.
  int get maxBreakAfterBlock {
    if (blockMinutes <= 0 || _span <= 0) return 0;
    final int fits = _span ~/ blockMinutes;
    return fits > 1 ? fits - 1 : 0;
  }

  int startOf(int index) => index < _beforeBreak
      ? dayStartMinutes + index * blockMinutes
      : breakEndMinutes + (index - _beforeBreak) * blockMinutes;

  /// Clamped to the end of the day, so the short final block reports the length
  /// it actually has.
  int endOf(int index) {
    final int end = startOf(index) + blockMinutes;
    return end > dayEndMinutes ? dayEndMinutes : end;
  }

  int lengthOf(int index) => endOf(index) - startOf(index);

  /// Rounds to the nearest block, so a 95-minute length typed by hand still
  /// reads as the two blocks it meant. Never less than one — a class always
  /// occupies the block it starts in.
  int blocksFor(int durationMinutes) {
    if (!isConfigured) return 1;
    final int blocks = (durationMinutes / blockMinutes).round();
    return blocks < 1 ? 1 : blocks;
  }

  int snapDuration(int durationMinutes) =>
      isConfigured ? blocksFor(durationMinutes) * blockMinutes : durationMinutes;

  /// Lets the UI say "2 blocks" only when that is exactly true, rather than
  /// rounding on the user's behalf.
  bool isWholeBlocks(int durationMinutes) =>
      isConfigured &&
      durationMinutes > 0 &&
      durationMinutes % blockMinutes == 0;

  /// The block containing [startMinutes], or null outside the day and inside
  /// the break.
  ///
  /// Floors rather than requiring a boundary: classes created before the grid
  /// existed need not sit on one, and showing them where they really are beats
  /// moving anyone's data to tidy the picture.
  int? indexOf(int startMinutes) {
    if (!isConfigured) return null;
    if (startMinutes < dayStartMinutes) return null;
    if (startMinutes >= dayEndMinutes) return null;
    if (_beforeBreak > 0 &&
        startMinutes >= breakStartMinutes &&
        startMinutes < breakEndMinutes) {
      return null;
    }
    final int index = startMinutes < breakStartMinutes
        ? (startMinutes - dayStartMinutes) ~/ blockMinutes
        : _beforeBreak + (startMinutes - breakEndMinutes) ~/ blockMinutes;
    return index >= blockCount ? null : index;
  }

  /// Asks the block itself rather than doing modular arithmetic, which is what
  /// keeps this honest once a break has shifted the afternoon off the original
  /// rhythm.
  bool isAligned(int startMinutes) {
    final int? index = indexOf(startMinutes);
    return index != null && startOf(index) == startMinutes;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DayGrid &&
          other.dayStartMinutes == dayStartMinutes &&
          other.dayEndMinutes == dayEndMinutes &&
          other.blockMinutes == blockMinutes &&
          other.breakAfterBlock == breakAfterBlock &&
          other.breakMinutes == breakMinutes);

  @override
  int get hashCode => Object.hash(
        dayStartMinutes,
        dayEndMinutes,
        blockMinutes,
        breakAfterBlock,
        breakMinutes,
      );
}
