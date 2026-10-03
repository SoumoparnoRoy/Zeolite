import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/day_grid.dart';
import '../../domain/home_widget_payload.dart';
import '../../domain/schedule_engine.dart';
import '../../services/home_widget_service.dart';
import '../../state/home_widget_providers.dart';
import '../../state/providers.dart';
import 'week_grid_view.dart';

/// Draws the real [WeekGridView] offscreen for the week widget whenever the
/// timetable or its settings move.
///
/// A picture rather than a native grid: rebuilding this layout in RemoteViews
/// would mean two grids that have to be kept looking alike by hand, and the
/// one thing worth having on a home screen is the week as the app draws it.
/// The cost is that taps land on a day column, not on a class. A widget
/// resized while the app is closed keeps the old shape until it is next opened.
final weekWidgetImageProvider = Provider<void>((Ref ref) {
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
  final AppSettings? settings = ref.watch(settingsProvider).value;
  if (engine == null || settings == null) return;
  unawaited(
    _render(
      service: ref.read(homeWidgetServiceProvider),
      container: ref.container,
      grid: ref.read(dayGridProvider),
      settings: settings,
    ),
  );
});

/// Only until the widget has drawn once and reported its own cell. The
/// minimum `widget_week_info.xml` declares, so a first render has the widget's
/// shape and room for the grid's empty state.
const Size _fallbackSize = Size(250, 290);

/// [WeekGridView]'s own floors and spacing, which are what a widget cell
/// cannot meet: a block will not go under [_minBlockHeight], so a full day
/// needs more height than any cell has.
const double _minBlockHeight = 46;
const double _blockGap = 4;
const double _gridHeaderHeight = 40;
const double _breakBandHeight = 26;

/// Past this the week stops being readable, and showing the morning at a
/// legible size beats showing the whole day at none. The widget asks for a
/// tall cell so this bound is rarely the one that bites.
const double _maxZoomOut = 2.2;

Future<void> _render({
  required HomeWidgetService service,
  required ProviderContainer container,
  required DayGrid grid,
  required AppSettings settings,
}) async {
  // The cell the widget actually occupies, written there by its provider,
  // because Dart has no way to ask. Drawn at that size the grid fills the
  // widget instead of being centred inside it.
  final Size cell = await service.weekCellSize() ?? _fallbackSize;

  // A widget cell is far shorter than the grid's own minimum block height
  // times a full day, so asking the grid to draw into it directly clipped
  // the afternoon off. Drawing into a taller box at the cell's own aspect
  // and letting the launcher scale the picture down shows the whole week
  // instead — the same trade as zooming out, and it undoes itself as the
  // widget is made taller.
  final double zoom = _zoomOut(grid, cell.height);
  final Size size = cell * zoom;

  await service.renderWeekImage(
    _WeekGridSnapshot(
      container: container,
      settings: settings,
      size: size,
      // The grid runs to the widget's own edges, so nothing else can round
      // its corners for it. Drawn at [zoom] and shown scaled back down,
      // which the radius has to be multiplied by to survive the trip.
      cornerRadius: AppSpacing.radiusLg * zoom,
    ),
    size: size,
  );
}

/// How much taller than the cell the grid has to be drawn for a whole day to
/// fit, given the height its own blocks refuse to go below. 1 when the cell is
/// already tall enough; capped, since past a point the week is a smear.
double _zoomOut(DayGrid grid, double cellHeight) {
  if (!grid.isConfigured || cellHeight <= 0) return 1;
  final double needed = _gridHeaderHeight +
      grid.blockCount * (_minBlockHeight + _blockGap) +
      (grid.hasBreak ? _breakBandHeight : 0);
  return (needed / cellHeight).clamp(1.0, _maxZoomOut);
}

/// The grid with the app's own theme and a fixed viewport around it, since a
/// widget render has neither a MediaQuery nor a Theme of its own.
class _WeekGridSnapshot extends StatelessWidget {
  const _WeekGridSnapshot({
    required this.container,
    required this.settings,
    required this.size,
    required this.cornerRadius,
  });

  final ProviderContainer container;
  final AppSettings settings;
  final Size size;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    final bool dark =
        HomeWidgetPayload.widgetBrightness(settings) == Brightness.dark;
    final ThemeData theme = dark
        ? AppTheme.dark(settings.accentColour)
        : AppTheme.light(settings.accentColour);

    return UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: Theme(
          data: theme,
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(cornerRadius),
            clipBehavior: Clip.antiAlias,
            child: SizedBox.fromSize(
              size: size,
              child: WeekGridView(
                weekStart: Dates.startOfWeek(Dates.today()),
                availableHeight: size.height,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
