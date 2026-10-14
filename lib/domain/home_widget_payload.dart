import 'package:flutter/widgets.dart';

import '../core/app_theme.dart';
import '../core/date_utils.dart';
import '../data/models/attendance_status.dart';
import '../data/models/class_session.dart';
import '../data/models/holiday.dart';
import '../data/settings/app_settings.dart';
import 'attendance_stats.dart';
import 'schedule_engine.dart';

/// What the home-screen widgets are given to draw.
///
/// Built here, in Dart, so the launcher never re-implements the schedule
/// expansion or the attendance maths in Kotlin against the same database. The
/// Android side reads these maps and does no arithmetic of its own.
class HomeWidgetPayload {
  const HomeWidgetPayload._();

  /// Every payload that depends on the date is written for this many days,
  /// starting today. The launcher redraws at midnight with the app closed and
  /// picks the new day's entry, so this is how long a widget stays right
  /// without the app being opened.
  static const int daysAhead = 7;

  /// The midnights the launcher has to redraw at, one per day after today
  /// that [daysAhead] covers, plus the one that runs off the end so the widget
  /// can say it has nothing for that day.
  static List<DateTime> dayChanges({DateTime? from}) {
    final DateTime today = Dates.dayOf(from ?? DateTime.now());
    return <DateTime>[
      for (int i = 1; i <= daysAhead; i++) Dates.addDays(today, i),
    ];
  }

  /// The Today widget's days, keyed by date for the launcher to look up.
  static Map<String, Object?> today({
    required ScheduleEngine engine,
    required AppSettings settings,
    DateTime? on,
  }) {
    final DateTime first = Dates.dayOf(on ?? DateTime.now());
    return <String, Object?>{
      'days': <Map<String, Object?>>[
        for (int i = 0; i < daysAhead; i++)
          day(engine: engine, settings: settings, on: Dates.addDays(first, i)),
      ],
    };
  }

  /// The day is described by a state rather than by an empty list, because
  /// "nothing scheduled", "a holiday" and "outside the term" are three
  /// different things to be told on a home screen.
  static Map<String, Object?> day({
    required ScheduleEngine engine,
    required AppSettings settings,
    required DateTime on,
  }) {
    final DateTime day = Dates.dayOf(on);
    final Holiday? holiday = engine.holidayOn(day);
    final List<ClassSession> sessions = engine.sessionsOn(day);

    final String state;
    if (engine.isOutsideTerm(day)) {
      state = 'outside';
    } else if (holiday != null) {
      state = 'holiday';
    } else if (sessions.isEmpty) {
      state = 'empty';
    } else {
      state = 'classes';
    }

    return <String, Object?>{
      'date': Dates.keyOf(day),
      'dateLabel': Dates.formatFull(day),
      'state': state,
      'holiday': holiday?.name,
      'classes': <Map<String, Object?>>[
        for (final ClassSession session in sessions)
          _session(session, settings),
      ],
    };
  }

  /// The one figure the app exists to answer, worded exactly as the home
  /// screen words it — [OverallStats.verdict] is the same string the header
  /// shows, so the two can never drift apart.
  ///
  /// [upcoming] is [HomeWidgetPayload.upcoming]: the caller schedules a redraw
  /// at each of those starts too, so it is worked out once and handed to both.
  static Map<String, Object?> standing({
    required List<ClassSession> upcoming,
    required OverallStats stats,
    required AppSettings settings,
    DateTime? now,
  }) {
    return <String, Object?>{
      'verdict': stats.verdict,
      'hasData': stats.hasData,
      'percent': stats.hasData ? stats.percent.round() : null,
      'target': (stats.target * 100).round(),
      'meetsTarget': stats.meetsTarget,
      // Every class still to start, not just the next: the launcher shows the
      // first that has not started when it draws, so the line moves on at
      // each class start with the app closed.
      'upcoming': <Map<String, Object?>>[
        for (final ClassSession session in upcoming)
          <String, Object?>{
            'subject': session.subject.name,
            'at': session.startDateTime.millisecondsSinceEpoch,
            'when': _whenByDay(session, settings, on: now),
          },
      ],
    };
  }

  /// The classes the Stats widget's "Next" line can name, in order: those
  /// starting within [daysAhead], or failing that the next one inside a
  /// fortnight, which is how far the app looks for one.
  static List<ClassSession> upcoming(ScheduleEngine engine, {DateTime? now}) {
    final DateTime at = now ?? DateTime.now();
    final DateTime today = Dates.dayOf(at);
    final DateTime windowEnd = Dates.addDays(today, daysAhead);
    final List<ClassSession> starting = engine
        .sessionsBetween(today, Dates.addDays(today, 14))
        .where((ClassSession s) => s.startDateTime.isAfter(at))
        .toList();
    final List<ClassSession> within =
        starting.where((ClassSession s) => s.date.isBefore(windowEnd)).toList();
    return within.isNotEmpty ? within : starting.take(1).toList();
  }

  /// "Tomorrow, 9:00 AM" stops being true at midnight, so the label is
  /// written for each day up to the class's own, keyed by date, and the
  /// launcher shows the one for the day it draws on. Past the class's day
  /// there is no entry and the line is hidden.
  static Map<String, String> _whenByDay(
    ClassSession next,
    AppSettings settings, {
    DateTime? on,
  }) {
    final DateTime today = Dates.dayOf(on ?? DateTime.now());
    final String time =
        Clock.format(next.startMinutes, use24Hour: settings.use24HourTime);
    final Map<String, String> when = <String, String>{};
    for (int i = 0; i < daysAhead; i++) {
      final DateTime day = Dates.addDays(today, i);
      if (day.isAfter(next.date)) break;
      when['${Dates.keyOf(day)}'] =
          '${Dates.relativeLabel(next.date, from: day)}, $time';
    }
    return when;
  }

  /// Every subject, weakest first.
  ///
  /// The order is the point: a widget shows as many rows as its cell has room
  /// for, and the ones that matter are those closest to their target — the
  /// Stats screen can afford to list subjects in its own order because it
  /// scrolls. Subjects with nothing marked sort last, since a subject at zero
  /// held is not in trouble, it is untouched.
  static Map<String, Object?> subjects(OverallStats stats) {
    final List<SubjectStats> ordered = stats.subjects.toList()
      ..sort((SubjectStats a, SubjectStats b) {
        if (a.hasData != b.hasData) return a.hasData ? -1 : 1;
        return a.ratio.compareTo(b.ratio);
      });

    return <String, Object?>{
      'target': (stats.target * 100).round(),
      'subjects': <Map<String, Object?>>[
        for (final SubjectStats subject in ordered)
          <String, Object?>{
            'name': subject.subject.name,
            'colour': subject.subject.colorValue,
            'hasData': subject.hasData,
            'percent': subject.hasData ? subject.percent.round() : null,
            'counts': subject.hasData
                ? '${subject.attended} of ${subject.held} attended'
                : 'Nothing marked yet',
            'headline': subject.headline,
            'health': subject.health.name,
            'meetsTarget': subject.meetsTarget,
          },
      ],
    };
  }

  /// Which brightness the launcher should be drawn in. A launcher gives no
  /// light/dark signal of its own, so System is resolved here — otherwise a
  /// widget would sit dark beside a light app.
  static Brightness widgetBrightness(AppSettings settings) =>
      switch (settings.themeMode) {
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
        // Through the binding, not `PlatformDispatcher.instance`: both callers
        // initialise one first, and only this form is overridable in a test.
        AppThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
      };

  /// The colours the launcher draws with.
  ///
  /// Sent rather than duplicated in `values-night`, because the widget follows
  /// the app's own theme choice — a user who runs the app dark on a light
  /// system would otherwise get a white widget beside a dark app.
  static Map<String, Object?> theme(AppSettings settings) {
    final AppPalette p = widgetBrightness(settings) == Brightness.light
        ? AppPalette.light
        : AppPalette.dark;
    return <String, Object?>{
      'canvas': p.canvas.toARGB32(),
      'surface': p.surface.toARGB32(),
      'surfaceHigh': p.surfaceHigh.toARGB32(),
      'outline': p.outline.toARGB32(),
      'accent': p.accent.toARGB32(),
      'textPrimary': p.textPrimary.toARGB32(),
      'textSecondary': p.textSecondary.toARGB32(),
      'textTertiary': p.textTertiary.toARGB32(),
      'present': p.present.toARGB32(),
      'absent': p.absent.toARGB32(),
      'cancelled': p.cancelled.toARGB32(),
      'warning': p.warning.toARGB32(),
    };
  }

  static Map<String, Object?> _session(
    ClassSession session,
    AppSettings settings,
  ) {
    final AttendanceStatus? status = session.status;
    return <String, Object?>{
      // The natural key, and the only part the mark handler trusts: everything
      // else here is a label that may already be stale by the time it is
      // tapped.
      'subjectId': session.subject.id,
      'date': Dates.keyOf(session.date),
      'startMinutes': session.startMinutes,
      'subject': session.subject.name,
      'time': Clock.formatRange(
        session.startMinutes,
        session.endMinutes,
        use24Hour: settings.use24HourTime,
      ),
      'room': session.room,
      'color': session.subject.colorValue,
      'status': status?.name,
    };
  }
}
