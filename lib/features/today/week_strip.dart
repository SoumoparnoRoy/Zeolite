import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';

/// Horizontally scrollable strip of days, sitting on the header gradient.
///
/// Renders a wide window either side of today and scrolls the selection into
/// view, so jumping weeks is a flick rather than a date picker. Cells are
/// sized so exactly [_visibleDays] fit the viewport.
class WeekStrip extends StatefulWidget {
  const WeekStrip({
    super.key,
    required this.selected,
    required this.onSelected,
    this.markers = const <int, DayMarker>{},
    this.horizontalPadding = 20,
    this.pastDays = 60,
    this.futureDays = 120,
  });

  final DateTime selected;
  final ValueChanged<DateTime> onSelected;

  /// Per-day dot summary, keyed by [Dates.keyOf].
  final Map<int, DayMarker> markers;

  final double horizontalPadding;
  final int pastDays;
  final int futureDays;

  @override
  State<WeekStrip> createState() => _WeekStripState();
}

/// What to draw under a day: how many classes and whether any are unmarked.
class DayMarker {
  const DayMarker({
    required this.count,
    this.hasUnmarked = false,
    this.color,
  });

  final int count;
  final bool hasUnmarked;
  final Color? color;
}

class _WeekStripState extends State<WeekStrip> {
  static const int _visibleDays = 5;
  static const double _gap = 6;

  final ScrollController _controller = ScrollController();

  late final DateTime _first = Dates.addDays(Dates.today(), -widget.pastDays);

  double _itemWidth = 56;

  @override
  void didUpdateWidget(covariant WeekStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!Dates.isSameDay(oldWidget.selected, widget.selected)) {
      _scrollTo(widget.selected, animate: true);
    }
  }

  double _offsetFor(DateTime date) {
    final int index = Dates.daysBetween(_first, date);
    final double raw = index * (_itemWidth + _gap);
    // Nudge the selection towards the middle rather than the left edge.
    return (raw - 2 * (_itemWidth + _gap)).clamp(0.0, double.infinity);
  }

  void _scrollTo(DateTime date, {bool animate = false}) {
    if (!_controller.hasClients) return;
    final double target = _offsetFor(date).clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    if (!animate) {
      _controller.jumpTo(target);
      return;
    }
    unawaited(_controller.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int total = widget.pastDays + widget.futureDays + 1;
    final DateTime today = Dates.today();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double usable =
            constraints.maxWidth - widget.horizontalPadding * 2;
        final double width =
            (usable - _gap * (_visibleDays - 1)) / _visibleDays;

        // The first layout has to land on the selected day without an
        // animation, and the offset depends on a width only known here.
        if ((width - _itemWidth).abs() > 0.5 || !_controller.hasClients) {
          _itemWidth = width;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollTo(widget.selected);
          });
        }

        // The pill is fixed-height chrome, so it has to grow with the system
        // font rather than clip the date. Capped, because past 1.35 the five
        // columns matter more than another point of size.
        final double scale = MediaQuery.textScalerOf(context).scale(10) / 10;
        final double capped = scale.clamp(1.0, 1.35);

        return SizedBox(
          height: 50 * capped,
          child: ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
            itemCount: total,
            separatorBuilder: (_, __) => const SizedBox(width: _gap),
            itemBuilder: (BuildContext context, int index) {
              final DateTime date = Dates.addDays(_first, index);
              return MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.35,
                child: _DayPill(
                  date: date,
                  selected: Dates.isSameDay(date, widget.selected),
                  isToday: Dates.isSameDay(date, today),
                  marker: widget.markers[Dates.keyOf(date)],
                  width: width,
                  onTap: () => widget.onSelected(date),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _DayPill extends StatelessWidget {
  const _DayPill({
    required this.date,
    required this.selected,
    required this.isToday,
    required this.width,
    required this.onTap,
    this.marker,
  });

  final DateTime date;
  final bool selected;
  final bool isToday;
  final double width;
  final VoidCallback onTap;
  final DayMarker? marker;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool weekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;

    // The selected day is the one white object on the gradient, so it reads
    // as lifted off it rather than as another translucent tile.
    final Color ink = selected
        ? p.gradientMid
        : Colors.white.withValues(alpha: weekend ? 0.5 : 0.85);

    return SizedBox(
      width: width,
      child: Material(
        color: selected
            ? (p.isDark ? const Color(0xFFF2F2F7) : Colors.white)
            : Colors.white.withValues(alpha: p.isDark ? 0.09 : 0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 7),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  Dates.weekdayShort(date).toUpperCase(),
                  style: TextStyle(
                    fontSize: AppType.captionMedium,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                    color: ink,
                  ),
                ),
                Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: AppType.titleMedium,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 3),
                _Dots(marker: marker, selected: selected, isToday: isToday),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({
    required this.selected,
    required this.isToday,
    this.marker,
  });

  final DayMarker? marker;
  final bool selected;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final DayMarker? m = marker;
    if (m == null || m.count == 0) {
      // Today keeps a mark even when empty, so the strip never loses its
      // anchor while you scroll away from it.
      if (!isToday || selected) return const SizedBox(height: 4);
      return Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
      );
    }

    final Color color = m.hasUnmarked
        ? (selected ? p.warning : const Color(0xFFFFCE85))
        : (selected
            ? p.gradientMid.withValues(alpha: 0.55)
            : Colors.white.withValues(alpha: 0.75));

    return SizedBox(
      height: 4,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (int i = 0; i < (m.count > 3 ? 3 : m.count); i++)
            Container(
              width: 4,
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 1.2),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }
}
