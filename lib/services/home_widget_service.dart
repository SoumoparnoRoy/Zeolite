import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import '../core/report_error.dart';

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
    } catch (error, stack) {
      reportError(error, stack, where: 'home widget update');
    }
  }

  /// Hands the launcher [picture], drawn offscreen at [size], as the week
  /// widget's image.
  ///
  /// Needs a real view to render into, so it only works while the app is in the
  /// foreground — the background mark handler leaves the last image in place.
  Future<void> renderWeekImage(Widget picture, {required Size size}) async {
    if (ui.PlatformDispatcher.instance.implicitView == null) return;
    try {
      await HomeWidget.renderFlutterWidget(
        picture,
        key: weekImageKey,
        logicalSize: size,
      );
      await _redraw();
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
