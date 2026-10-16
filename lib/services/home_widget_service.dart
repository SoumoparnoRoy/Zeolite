import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import '../core/date_utils.dart';
import '../core/report_error.dart';
import '../domain/home_widget_payload.dart';

/// Pushes what the home-screen widgets draw, and asks Android to redraw them.
///
/// Everything here is best-effort: a launcher that refuses an update, or a
/// device with no widget placed at all, must never surface as a failure in the
/// app that just marked a class.
class HomeWidgetService {
  const HomeWidgetService();

  static const String todayKey = 'today';

  /// One picture per weekday, since the grid marks today's column and so
  /// changes at every midnight. Seven days ahead never hold the same weekday
  /// twice, so the slots never collide. [weekImageDatesKey] says which date
  /// each slot was drawn for, so a picture is never shown on the wrong day.
  static String weekImageKey(DateTime day) => 'weekImage${day.weekday}';
  static const String weekImageDatesKey = 'weekImageDates';
  static const String standingKey = 'standing';
  static const String subjectsKey = 'subjects';
  static const String themeKey = 'theme';

  /// Stamped by the background mark handler and compared by the app on resume.
  /// A plain timestamp: the app only cares that it moved.
  static const String markEpochKey = 'markEpoch';

  /// Each tap the Today widget draws before Dart has saved it is its own
  /// entry, `pendingMark:<subjectId:date:start>@<millis>`, written by
  /// `WidgetMarkReceiver`. The run that saves a tap removes that entry and no
  /// other; one never saved lapses on the Kotlin side.
  static String pendingMarkKey(PendingTap tap) =>
      'pendingMark:${tap.key}@${tap.at}';

  /// The week widget's own cell, in dp, written by its provider.
  static const String weekCellKey = 'weekCell';

  static const double _maxRender = 900;

  static const String _package = 'com.soumoparno.zeolite';

  static const List<String> _providers = <String>[
    'TodayWidgetProvider',
    'WeekWidgetProvider',
    'StatsWidgetProvider',
  ];

  /// The scheme the widget's own taps come back on. `mark` goes through
  /// `WidgetMarkReceiver`, which draws the tap and wakes the background
  /// isolate; `open` goes to the activity.
  static const String scheme = 'zeolite';

  /// What this process last handed the launcher. The clock rebuilds the stats
  /// at every class start and end and on every resume, and most of those
  /// change nothing the widgets show; each still wrote four keys and redrew
  /// every widget.
  static String? _lastPushed;

  Future<void> push({
    required Map<String, Object?> today,
    required Map<String, Object?> standing,
    required Map<String, Object?> subjects,
    required Map<String, Object?>? theme,
    required List<DateTime> classStarts,
    PendingTap? settles,
  }) async {
    final String pushed = jsonEncode(<Object?>[
      today,
      standing,
      subjects,
      theme,
      <int>[for (final DateTime at in classStarts) at.millisecondsSinceEpoch],
    ]);
    // A tap to settle always goes through: the widget is showing it as
    // pending until this redraw.
    if (settles == null && pushed == _lastPushed) return;
    try {
      await HomeWidget.saveWidgetData<String>(todayKey, jsonEncode(today));
      await HomeWidget.saveWidgetData<String>(
        standingKey,
        jsonEncode(standing),
      );
      await HomeWidget.saveWidgetData<String>(
        subjectsKey,
        jsonEncode(subjects),
      );
      if (theme != null) {
        await HomeWidget.saveWidgetData<String>(themeKey, jsonEncode(theme));
      }
      if (settles != null) await _settle(settles);
      await _redraw();
      await _scheduleRedraws(classStarts);
      _lastPushed = pushed;
    } catch (error, stack) {
      reportError(error, stack, where: 'home widget update');
    }
  }

  /// Hands the launcher [picture], drawn offscreen at [size], as the week
  /// widget's image for [day].
  ///
  /// Needs a real view to render into, so it only works while the app is in the
  /// foreground — the background mark handler leaves the last image in place.
  Future<void> renderWeekImage(
    Widget picture, {
    required DateTime day,
    required Size size,
  }) {
    // One at a time: each reads [weekImageDatesKey], adds its day and writes
    // it back, and two overlapping — a mark's redraw over the coming days
    // still drawing — could each write over the other's day.
    final Future<void> next = _weekImages
        .then((_) => _renderWeekImage(picture, day: day, size: size));
    _weekImages = next;
    return next;
  }

  static Future<void> _weekImages = Future<void>.value();

  Future<void> _renderWeekImage(
    Widget picture, {
    required DateTime day,
    required Size size,
  }) async {
    if (ui.PlatformDispatcher.instance.implicitView == null) return;
    try {
      await _forgetSingleWeekImage();
      await HomeWidget.renderFlutterWidget(
        picture,
        key: weekImageKey(day),
        logicalSize: size,
      );
      final String? raw =
          await HomeWidget.getWidgetData<String>(weekImageDatesKey);
      final Map<String, Object?> dates = raw == null
          ? <String, Object?>{}
          : jsonDecode(raw) as Map<String, Object?>;
      dates['${Dates.keyOf(day)}'] = weekImageKey(day);
      // A slot drawn for an earlier date has been overwritten by this one.
      dates.removeWhere(
        (String date, Object? key) =>
            key == weekImageKey(day) && date != '${Dates.keyOf(day)}',
      );
      await HomeWidget.saveWidgetData<String>(
        weekImageDatesKey,
        jsonEncode(dates),
      );
      if (Dates.isSameDay(day, Dates.today())) await _redraw();
    } catch (error, stack) {
      reportError(error, stack, where: 'week widget image');
    }
  }

  /// "WIDTHxHEIGHT" in dp, or null before the widget has ever drawn. Capped
  /// because the render is a bitmap and a launcher is free to report a cell as
  /// large as it likes.
  Future<Size?> weekCellSize() async {
    try {
      final String? raw = await HomeWidget.getWidgetData<String>(weekCellKey);
      final List<String> parts = (raw ?? '').split('x');
      if (parts.length != 2) return null;
      final double? width = double.tryParse(parts.first);
      final double? height = double.tryParse(parts.last);
      if (width == null || height == null || width <= 0 || height <= 0) {
        return null;
      }
      return Size(math.min(width, _maxRender), math.min(height, _maxRender));
    } catch (error, stack) {
      reportError(error, stack, where: 'reading the week widget size');
      return null;
    }
  }

  /// Removes what the widget drew for [tap] once it is saved. Its own entry
  /// only: a later tap on the same class is still on its way, and a tap with
  /// no stamp (a notification action) drew nothing to take back.
  Future<void> _settle(PendingTap tap) async {
    if (tap.at == null) return;
    await HomeWidget.saveWidgetData<String>(pendingMarkKey(tap), null);
  }

  /// Takes back what the Today widget drew for [mark] when there is no
  /// payload to push in its place, so the widget falls back to the last one.
  Future<void> settleOnly(PendingTap mark) async {
    try {
      await _settle(mark);
      await _redraw();
    } catch (error, stack) {
      reportError(error, stack, where: 'home widget settle');
    }
  }

  /// Before one picture per day there was one under `weekImage`; clearing the
  /// key deletes its file. `week` held the dates behind the old per-day taps.
  /// Once per run is enough.
  static bool _singleWeekImageGone = false;
  Future<void> _forgetSingleWeekImage() async {
    if (_singleWeekImageGone) return;
    await HomeWidget.saveWidgetData<String>('weekImage', null);
    await HomeWidget.saveWidgetData<String>('week', null);
    _singleWeekImageGone = true;
  }

  /// Asks Android to redraw every widget at each coming midnight, when each
  /// picks the new day out of what was pushed, and the Stats widget at each
  /// class start too, when its "Next" line moves on. Through the plugin's own
  /// scheduler, which keeps the alarms across a reboot or an app update.
  Future<void> _scheduleRedraws(List<DateTime> classStarts) async {
    final List<DateTime> midnights = HomeWidgetPayload.dayChanges();
    for (final String provider in _providers) {
      final List<DateTime> times = provider == 'StatsWidgetProvider'
          ? <DateTime>[...midnights, ...classStarts]
          : midnights;
      // Every mark pushes, and the times rarely move with it.
      final String key =
          times.map((DateTime t) => t.millisecondsSinceEpoch).join(',');
      if (_scheduled[provider] == key) continue;
      await HomeWidget.scheduleWidgetUpdates(
        times,
        qualifiedAndroidName: '$_package.widget.$provider',
      );
      _scheduled[provider] = key;
    }
  }

  static final Map<String, String> _scheduled = <String, String>{};

  Future<void> _redraw() async {
    for (final String provider in _providers) {
      await HomeWidget.updateWidget(
        qualifiedAndroidName: '$_package.widget.$provider',
      );
    }
  }
}

/// A tap the Today widget drew ahead of Dart: the class it is filed under,
/// and when `WidgetMarkReceiver` drew it, which tells it apart from a later
/// tap on the same class. Null [at] for a tap that came some other way.
typedef PendingTap = ({String key, String? at});
