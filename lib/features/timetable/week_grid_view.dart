import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/class_session.dart';
import '../../domain/day_grid.dart';
import '../../domain/schedule_engine.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../subjects/class_editor_sheets.dart';

/// The week as a grid: uniform lecture blocks down the side, weekdays across.
///
/// Laid out as a row of per-day columns rather than a column of rows, because a
/// class spanning several blocks is then simply a taller tile in one column.
/// Every column sums to the same height, so the blocks stay aligned across days
/// without any of the arithmetic a row-spanning table would need.
///
/// All seven columns fit the screen — a grid that scrolls sideways loses the
/// one thing it beats a list at. The price is a two-letter code per tile
/// instead of the subject name.
class WeekGridView extends ConsumerWidget {
  const WeekGridView({
    super.key,
    required this.weekStart,
    this.availableHeight,
  });

  final DateTime weekStart;

  /// Room the viewport can give the grid, when the caller knows it. The blocks
  /// share it out; without it they fall back to [_minBlockHeight].
  final double? availableHeight;

  /// A block is given whatever height the viewport can spare, between these.
  ///
  /// The floor is what a dense day falls back to — fourteen blocks cannot fit
  /// a screen unsquashed, so that day scrolls. The ceiling stops a three-block
  /// day becoming three slabs.
  static const double _minBlockHeight = 46;
  static const double _maxBlockHeight = 88;

  static const double _gap = 4;

  /// Wider in 12-hour mode, where the ruler carries "AM"/"PM" as well.
  static const double _gutterWidth = 34;
  static const double _gutterWidthMeridiem = 48;

  static const double _headerHeight = 34;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The cells carry text, so their geometry has to ride the same ramp the
    // type does or the tablet gets bigger labels in phone-sized boxes.
    final double scale = AppScale.of(MediaQuery.sizeOf(context));
    final double gap = _gap * scale;
    final double headerHeight = _headerHeight * scale;

    final DayGrid grid = ref.watch(dayGridProvider);
    final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
    final bool use24Hour =
        ref.watch(settingsProvider).value?.use24HourTime ?? false;
    final double gutterWidth =
        (use24Hour ? _gutterWidth : _gutterWidthMeridiem) * scale;

    if (!grid.isConfigured) return const _NotConfigured();

    final Map<int, List<ClassSession>> byDay =
        engine?.sessionsForWeekOf(weekStart) ?? <int, List<ClassSession>>{};

    // The break splits the grid into two bands of blocks so the strip between
    // them can run the whole width. Drawing it inside each day column instead
    // would leave it broken by the column gaps, and a dashed line across seven
    // columns reads as more empty cells rather than as a pause in the day.
    final int split = grid.hasBreak ? grid.breakAfterBlock : grid.blockCount;
    final double bandHeight = grid.hasBreak ? _BreakBand.height * scale : 0;

    // Everything the blocks do not get: names, break strip, gaps.
    final double? room = availableHeight;
    final double spare = room == null
        ? 0
        : room -
            headerHeight -
            bandHeight -
            gap * (grid.blockCount + (grid.hasBreak ? 2 : 0));
    final double blockHeight = room == null
        ? _minBlockHeight * scale
        : (spare / grid.blockCount)
            .clamp(_minBlockHeight * scale, _maxBlockHeight * scale);

    Widget rows(int from, int to) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _TimeGutter(
              grid: grid,
              use24Hour: use24Hour,
              blockHeight: blockHeight,
              gap: gap,
              width: gutterWidth,
              from: from,
              to: to,
            ),
            for (int i = 0; i < 7; i++) ...<Widget>[
              SizedBox(width: gap),
              Expanded(
                child: _DayColumn(
                  date: Dates.addDays(weekStart, i),
                  sessions: byDay[Dates.keyOf(Dates.addDays(weekStart, i))] ??
                      const <ClassSession>[],
                  grid: grid,
                  use24Hour: use24Hour,
                  blockHeight: blockHeight,
                  gap: gap,
                  from: from,
                  to: to,
                  holiday: engine?.holidayOn(Dates.addDays(weekStart, i))?.name,
                  // With a break the column is drawn in two halves; naming the
                  // day in both would say it twice.
                  nameHoliday: from == 0,
                ),
              ),
            ],
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          // Fixed, so the room left for the blocks is arithmetic, not a guess.
          height: headerHeight,
          child: Row(
            children: <Widget>[
              SizedBox(width: gutterWidth),
              for (int i = 0; i < 7; i++) ...<Widget>[
                SizedBox(width: gap),
                Expanded(child: _DayHeader(date: Dates.addDays(weekStart, i))),
              ],
            ],
          ),
        ),
        SizedBox(height: gap),
        rows(0, split),
        if (grid.hasBreak) ...<Widget>[
          SizedBox(height: gap),
          _BreakBand(grid: grid, use24Hour: use24Hour, scale: scale),
          SizedBox(height: gap),
          rows(split, grid.blockCount),
        ],
      ],
    );
  }
}

/// The gap between the morning and the afternoon.
///
/// Deliberately shorter and flatter than a block: it is not somewhere a class
/// can go, and giving it a cell's height would invite tapping it.
class _BreakBand extends StatelessWidget {
  const _BreakBand({
    required this.grid,
    required this.use24Hour,
    required this.scale,
  });

  static const double height = 20;

  final DayGrid grid;
  final bool use24Hour;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String from = Clock.format(grid.breakStartMinutes,
        use24Hour: use24Hour);
    final String to = Clock.format(grid.breakEndMinutes, use24Hour: use24Hour);

    return Container(
      height: height * scale,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: p.isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.white.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Text(
        'Break  $from – $to',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: monoStyle(
          color: p.textFaint,
          size: 8,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Shown until the day has been divided into blocks, since without a block
/// length there is no grid to draw.
class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      child: EmptyState(
        icon: Icons.grid_view_rounded,
        title: 'Divide your day up first',
        message: 'The grid needs to know when your day starts and ends and how '
            'long one lecture runs. Set that in Settings → The teaching day, '
            'then fill the grid in by tapping the empty blocks.',
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool isToday = Dates.isSameDay(date, Dates.today());
    final bool weekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
    final Color ink =
        isToday ? p.accent : (weekend ? p.textFaint : p.textTertiary);

    return Column(
      children: <Widget>[
        Text(
          kWeekdayNamesShort[date.weekday - 1].substring(0, 1).toUpperCase(),
          style: TextStyle(
            fontSize: 8.5,
            height: 1.2,
            fontWeight: isToday ? FontWeight.w800 : FontWeight.w700,
            color: ink,
          ),
        ),
        Text(
          '${date.day}',
          style: TextStyle(
            fontSize: 8.5,
            height: 1.2,
            fontWeight: isToday ? FontWeight.w800 : FontWeight.w700,
            color: ink,
          ),
        ),
      ],
    );
  }
}

class _TimeGutter extends StatelessWidget {
  const _TimeGutter({
    required this.grid,
    required this.use24Hour,
    required this.blockHeight,
    required this.gap,
    required this.width,
    required this.from,
    required this.to,
  });

  final DayGrid grid;
  final bool use24Hour;
  final double blockHeight;
  final double gap;
  final double width;

  /// Half-open range of blocks, so the two sides of a break each draw their own.
  final int from;
  final int to;

  /// When a block starts, in the same words as every other time in the app.
  ///
  /// Through `Clock.format` rather than a formatter of its own: the ruler used
  /// to drop the meridiem to fit a narrower gutter, which is the one place a
  /// 12-hour time appeared without it.
  String _label(int index) =>
      Clock.format(grid.startOf(index), use24Hour: use24Hour);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        children: <Widget>[
          for (int i = from; i < to; i++) ...<Widget>[
            if (i > from) SizedBox(height: gap),
            SizedBox(
              height: blockHeight,
              child: Center(
                child: Text(
                  _label(i),
                  maxLines: 1,
                  softWrap: false,
                  style: monoStyle(
                    color: context.palette.textFaint,
                    size: 8,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One weekday: a tile per class, an empty cell per free block.
class _DayColumn extends ConsumerWidget {
  const _DayColumn({
    required this.date,
    required this.sessions,
    required this.grid,
    required this.use24Hour,
    required this.blockHeight,
    required this.gap,
    required this.from,
    required this.to,
    this.holiday,
    this.nameHoliday = true,
  });

  /// The holiday's name when this day is one, which blanks the recurring
  /// classes. A one-off class on a holiday is deliberate and still shows.
  final String? holiday;
  final bool nameHoliday;

  final DateTime date;
  final List<ClassSession> sessions;
  final DayGrid grid;
  final bool use24Hour;
  final double blockHeight;
  final double gap;

  final int from;
  final int to;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool weekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;

    // Group by the block each class starts in. Two classes in one block do
    // happen — a clash, or a subject entered twice — so a cell holds a list
    // rather than a single session.
    final Map<int, List<ClassSession>> byBlock = <int, List<ClassSession>>{};
    for (final ClassSession session in sessions) {
      final int? index = grid.indexOf(session.startMinutes);
      if (index == null) continue; // Outside the configured day.
      byBlock.putIfAbsent(index, () => <ClassSession>[]).add(session);
    }

    final List<Widget> cells = <Widget>[];
    int block = from;
    bool named = false;
    while (block < to) {
      // A blank column says nothing about why it is blank. Runs of free
      // blocks merge into one panel so the day reads as blocked.
      final String? holidayName = holiday;
      if (holidayName != null && byBlock[block] == null) {
        int run = 0;
        while (block + run < to && byBlock[block + run] == null) {
          run++;
        }
        if (cells.isNotEmpty) cells.add(SizedBox(height: gap));
        cells.add(
          SizedBox(
            height: blockHeight * run + gap * (run - 1),
            child: _HolidayCell(
              name: nameHoliday && !named ? holidayName : null,
            ),
          ),
        );
        named = true;
        block += run;
        continue;
      }

      // Copied out of the loop variable before any closure captures it — a
      // callback that closed over `block` itself would read whatever the loop
      // had advanced to by the time it ran, which is one past the last block.
      final int index = block;
      final List<ClassSession>? here = byBlock[index];
      if (cells.isNotEmpty) cells.add(SizedBox(height: gap));

      if (here == null) {
        cells.add(
          SizedBox(
            height: blockHeight,
            child: _EmptyCell(
              dimmed: weekend,
              onTap: () => showBlockClassEditor(
                context,
                ref,
                date: date,
                blockIndex: index,
              ),
            ),
          ),
        );
        block += 1;
        continue;
      }

      // A cell is as tall as its longest class, clamped to the end of the day
      // so the column cannot outgrow its neighbours.
      int span = 1;
      for (final ClassSession session in here) {
        final int blocks = grid.blocksFor(session.durationMinutes);
        if (blocks > span) span = blocks;
      }
      final int remaining = to - index;
      if (span > remaining) span = remaining;

      cells.add(
        SizedBox(
          height: blockHeight * span + gap * (span - 1),
          child: Column(
            children: <Widget>[
              for (final ClassSession session in here)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: session == here.last ? 0 : 2,
                    ),
                    child: _ClassCell(
                      session: session,
                      offGrid: !grid.isAligned(session.startMinutes),
                      use24Hour: use24Hour,
                      onTap: () => showSessionEditor(context, ref, session),
                      onLongPress: () =>
                          showSessionOptions(context, ref, session),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      block += span;
    }

    return Column(children: cells);
  }
}

/// A day the timetable does not run, drawn instead of left empty.
class _HolidayCell extends StatelessWidget {
  const _HolidayCell({this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.warning.withValues(alpha: p.isDark ? 0.07 : 0.13),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: name == null
          ? const SizedBox.expand()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
              child: Center(
                child: Text(
                  name!,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: p.warning,
                  ),
                ),
              ),
            ),
    );
  }
}

/// A free block. Borderless — outlining forty of them was what made a mostly
/// empty week look full — but it keeps a very faint plus, because tapping one
/// is the only way into the block editor and an invisible affordance is not
/// one.
class _EmptyCell extends StatelessWidget {
  const _EmptyCell({required this.onTap, this.dimmed = false});

  final VoidCallback onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Material(
      color: p.isDark
          ? Colors.white.withValues(alpha: dimmed ? 0.02 : 0.04)
          : Colors.white.withValues(alpha: dimmed ? 0.28 : 0.5),
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Center(
          child: Icon(
            Icons.add_rounded,
            size: 12,
            color: p.textFaint.withValues(alpha: dimmed ? 0.25 : 0.4),
          ),
        ),
      ),
    );
  }
}

class _ClassCell extends StatelessWidget {
  const _ClassCell({
    required this.session,
    required this.offGrid,
    required this.use24Hour,
    required this.onTap,
    required this.onLongPress,
  });

  final ClassSession session;

  /// The class does not start on a block boundary — usually because it was
  /// created before the grid existed. Flagged rather than silently moved.
  final bool offGrid;

  final bool use24Hour;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color color = session.subject.color;
    final AttendanceStatus? status = session.status;
    final bool cancelled = status == AttendanceStatus.cancelled;

    return Opacity(
      opacity: cancelled ? 0.5 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          boxShadow: p.isDark
              ? const <BoxShadow>[]
              : <BoxShadow>[
                  BoxShadow(
                    color: p.cardShadow,
                    blurRadius: 9,
                    offset: const Offset(0, 3),
                  ),
                ],
        ),
        child: Material(
          color: p.surface,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(width: 3, color: color),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 5, 3, 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                session.subject.initials,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: TextStyle(
                                  fontSize: 8,
                                  height: 1,
                                  fontWeight: FontWeight.w800,
                                  color: p.textPrimary,
                                  decoration: cancelled
                                      ? TextDecoration.lineThrough
                                      : null,
                                  decorationColor: p.textFaint,
                                ),
                              ),
                            ),
                            if (status != null && !cancelled)
                              Container(
                                width: 4,
                                height: 4,
                                margin: const EdgeInsets.only(top: 1),
                                decoration: BoxDecoration(
                                  color: status.colorIn(p),
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          offGrid
                              ? Clock.format(
                                  session.startMinutes,
                                  use24Hour: use24Hour,
                                )
                              : (session.room ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: monoStyle(
                            color: offGrid ? p.warning : p.textTertiary,
                            size: 7,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
