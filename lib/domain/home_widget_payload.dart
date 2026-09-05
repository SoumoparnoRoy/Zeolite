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

  /// The day is described by a state rather than by an empty list, because
  /// "nothing scheduled", "a holiday" and "outside the term" are three
  /// different things to be told on a home screen.
  static Map<String, Object?> today({
    required ScheduleEngine engine,
    required AppSettings settings,
    DateTime? on,
  }) {
    final DateTime day = Dates.dayOf(on ?? DateTime.now());
    final Holiday? holiday = engine.holidayOn(day);
    final List<ClassSession> sessions = engine.sessionsOn(day);

    final String state;
    if (engine.isOutsideSemester(day)) {
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

  /// The whole week keyed by date, for the grid image and its day columns.
  static Map<String, Object?> week({
    required ScheduleEngine engine,
    DateTime? on,
  }) {
    final DateTime monday = Dates.startOfWeek(Dates.dayOf(on ?? DateTime.now()));
    final Map<int, List<ClassSession>> byDay = engine.sessionsForWeekOf(monday);
    return <String, Object?>{
      'monday': Dates.keyOf(monday),
      'label': '${Dates.formatDayMonth(monday)} – '
          '${Dates.formatDayMonth(Dates.addDays(monday, 6))}',
      'unmarked': <int>[
        for (int i = 0; i < 7; i++)
          (byDay[Dates.keyOf(Dates.addDays(monday, i))] ?? const <ClassSession>[])
              .where((ClassSession s) => s.needsMarking)
              .length,
      ],
    };
  }

  /// The one figure the app exists to answer, worded exactly as the home
  /// screen words it — [OverallStats.verdict] is the same string the header
  /// shows, so the two can never drift apart.
  static Map<String, Object?> standing({
    required ScheduleEngine engine,
    required OverallStats stats,
    required AppSettings settings,
  }) {
    final ClassSession? next = engine.nextSession();
    return <String, Object?>{
      'verdict': stats.verdict,
      'hasData': stats.hasData,
      'percent': stats.hasData ? stats.percent.round() : null,
      'target': (stats.target * 100).round(),
      'meetsTarget': stats.meetsTarget,
      'next': next == null
          ? null
          : <String, Object?>{
              'subject': next.subject.name,
              'when': '${Dates.relativeLabel(next.date)}, '
                  '${Clock.format(next.startMinutes, use24Hour: settings.use24HourTime)}',
            },
    };
  }

  /// Every subject, weakest first.
  ///
  /// The order is the point: a widget shows four rows, and the four that matter
  /// are the ones closest to their target — the Stats screen can afford to list
  /// subjects in its own order because it scrolls. Subjects with nothing marked
  /// sort last, since a subject at zero held is not in trouble, it is untouched.
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

  /// The colours the launcher draws with.
  ///
  /// Sent rather than duplicated in `values-night`, because the widget follows
  /// the app's own theme choice — a user who runs the app dark on a light
  /// system would otherwise get a white widget beside a dark app.
  static Map<String, Object?> theme(AppSettings settings) {
    final AppPalette p = settings.themeMode == AppThemeMode.light
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
