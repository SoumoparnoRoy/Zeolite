import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../core/app_theme.dart';
import '../core/date_utils.dart';
import '../data/settings/app_settings.dart';
import '../domain/day_grid.dart';
import '../domain/home_widget_payload.dart';
import '../features/timetable/week_grid_view.dart';
import '../state/providers.dart';

/// Pushes what the home-screen widgets draw, and asks Android to redraw them.
///
/// Everything here is best-effort: a launcher that refuses an update, or a
/// device with no widget placed at all, must never surface as a failure in the
/// app that just marked a class.
class HomeWidgetService {
  const HomeWidgetService();

  static const String todayKey = 'today';
  static const String weekKey = 'week';
  static const String weekImageKey = 'weekImage';
  static const String standingKey = 'standing';
  static const String subjectsKey = 'subjects';
  static const String themeKey = 'theme';

  /// Stamped by the background mark handler and compared by the app on resume.
  /// A plain timestamp: the app only cares that it moved.
  static const String markEpochKey = 'markEpoch';

  /// The week widget's own cell, in dp, written by its provider.
  static const String weekCellKey = 'weekCell';

  static const double _maxRender = 900;

  /// [WeekGridView]'s own floors and spacing, which are what a widget cell
  /// cannot meet: a block will not go under [_minBlockHeight], so a full day
  /// needs more height than any cell has.
  static const double _minBlockHeight = 46;
  static const double _blockGap = 4;
  static const double _gridHeaderHeight = 40;
  static const double _breakBandHeight = 26;

  /// Past this the week stops being readable, and showing the morning at a
  /// legible size beats showing the whole day at none. The widget asks for a
  /// tall cell so this bound is rarely the one that bites.
  static const double _maxZoomOut = 2.2;

  static const String _package = 'com.soumoparno.zeolite';

  /// The scheme the widget's own taps come back on. `mark` wakes the
  /// background isolate; `open` goes to the activity.
  static const String scheme = 'zeolite';

  Future<void> push({
    required Map<String, Object?> today,
    required Map<String, Object?> week,
    required Map<String, Object?> standing,
    required Map<String, Object?> subjects,
    required Map<String, Object?> theme,
  }) async {
    try {
      await HomeWidget.saveWidgetData<String>(todayKey, jsonEncode(today));
      await HomeWidget.saveWidgetData<String>(weekKey, jsonEncode(week));
      await HomeWidget.saveWidgetData<String>(
        standingKey,
        jsonEncode(standing),
      );
      await HomeWidget.saveWidgetData<String>(
        subjectsKey,
        jsonEncode(subjects),
      );
      await HomeWidget.saveWidgetData<String>(themeKey, jsonEncode(theme));
      await _redraw();
    } catch (error) {
      debugPrint('Home widget update skipped: $error');
    }
  }

  /// Draws the real [WeekGridView] offscreen and hands the launcher the PNG.
  ///
  /// A picture rather than a native grid: rebuilding this layout in RemoteViews
  /// would mean two grids that have to be kept looking alike by hand, and the
  /// one thing worth having on a home screen is the week as the app draws it.
  /// The cost is that taps land on a day column, not on a class.
  ///
  /// Needs a real view to render into, so it only works while the app is in the
  /// foreground — the background mark handler leaves the last image in place.
  /// A widget resized while the app is closed therefore keeps the old shape
  /// until it is next opened.
  Future<void> renderWeek({
    required ProviderContainer container,
    required AppSettings settings,
    required Size fallbackSize,
  }) async {
    final ui.FlutterView? view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) return;
    try {
      // The cell the widget actually occupies, written there by its provider,
      // because Dart has no way to ask. Drawn at that size the grid fills the
      // widget instead of being centred inside it.
      final Size cell = await _cellSize() ?? fallbackSize;

      // A widget cell is far shorter than the grid's own minimum block height
      // times a full day, so asking the grid to draw into it directly clipped
      // the afternoon off. Drawing into a taller box at the cell's own aspect
      // and letting the launcher scale the picture down shows the whole week
      // instead — the same trade as zooming out, and it undoes itself as the
      // widget is made taller.
      final double zoom = _zoomOut(container, cell.height);
      final Size size = cell * zoom;

      await HomeWidget.renderFlutterWidget(
        _WeekGridSnapshot(
          container: container,
          settings: settings,
          size: size,
          // The grid runs to the widget's own edges, so nothing else can round
          // its corners for it. Drawn at [zoom] and shown scaled back down,
          // which the radius has to be multiplied by to survive the trip.
          cornerRadius: AppSpacing.radiusLg * zoom,
        ),
        key: weekImageKey,
        logicalSize: size,
      );
      await _redraw();
    } catch (error) {
      debugPrint('Week widget image skipped: $error');
    }
  }

  /// How much taller than the cell the grid has to be drawn for a whole day to
  /// fit, given the height its own blocks refuse to go below. 1 when the cell is
  /// already tall enough; capped, since past a point the week is a smear.
  double _zoomOut(ProviderContainer container, double cellHeight) {
    final DayGrid grid = container.read(dayGridProvider);
    if (!grid.isConfigured || cellHeight <= 0) return 1;
    final double needed = _gridHeaderHeight +
        grid.blockCount * (_minBlockHeight + _blockGap) +
        (grid.hasBreak ? _breakBandHeight : 0);
    return (needed / cellHeight).clamp(1.0, _maxZoomOut);
  }

  /// "WIDTHxHEIGHT" in dp, or null before the widget has ever drawn. Capped
  /// because the render is a bitmap and a launcher is free to report a cell as
  /// large as it likes.
  Future<Size?> _cellSize() async {
    final String? raw = await HomeWidget.getWidgetData<String>(weekCellKey);
    final List<String> parts = (raw ?? '').split('x');
    if (parts.length != 2) return null;
    final double? width = double.tryParse(parts.first);
    final double? height = double.tryParse(parts.last);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(math.min(width, _maxRender), math.min(height, _maxRender));
  }

  Future<void> _redraw() async {
    for (final String provider in const <String>[
      'TodayWidgetProvider',
      'WeekWidgetProvider',
      'StatsWidgetProvider',
    ]) {
      await HomeWidget.updateWidget(
        qualifiedAndroidName: '$_package.widget.$provider',
      );
    }
  }
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
