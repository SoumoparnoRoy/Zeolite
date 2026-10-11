import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/domain/home_widget_payload.dart';
import 'package:zeolite/domain/schedule_engine.dart';

/// A Monday, so the one weekly rule below lands on it.
final DateTime monday = DateTime(2026, 8, 3);

final Subject subject = Subject(id: 1, name: 'Physics', colorValue: 0xFF7C6BFF);

ClassSlot slot({int start = 9 * 60, int end = 10 * 60}) => ClassSlot(
      id: 1,
      subjectId: 1,
      weekday: DateTime.monday,
      startMinutes: start,
      endMinutes: end,
      startDate: monday,
    );

ScheduleEngine engineWith({
  List<ExtraClass> extras = const <ExtraClass>[],
  List<Holiday> holidays = const <Holiday>[],
  List<AttendanceRecord> records = const <AttendanceRecord>[],
  DateTime? termStart,
  DateTime? termEnd,
}) =>
    ScheduleEngine(
      subjects: <Subject>[subject],
      slots: <ClassSlot>[slot()],
      extras: extras,
      holidays: holidays,
      records: records,
      termStart: termStart,
      termEnd: termEnd,
    );

void main() {
  group('the day the widget is told about', () {
    test('names the four states apart rather than sending an empty list', () {
      expect(
        HomeWidgetPayload.day(
          engine: engineWith(),
          settings: const AppSettings(),
          on: monday,
        )['state'],
        'classes',
      );

      // Tuesday: the rule does not apply, but the term is running.
      expect(
        HomeWidgetPayload.day(
          engine: engineWith(),
          settings: const AppSettings(),
          on: Dates.addDays(monday, 1),
        )['state'],
        'empty',
      );

      final Map<String, Object?> holiday = HomeWidgetPayload.day(
        engine: engineWith(
          holidays: <Holiday>[Holiday(date: monday, name: 'Founders Day')],
        ),
        settings: const AppSettings(),
        on: monday,
      );
      expect(holiday['state'], 'holiday');
      expect(holiday['holiday'], 'Founders Day');

      expect(
        HomeWidgetPayload.day(
          engine: engineWith(
            termStart: monday,
            termEnd: Dates.addDays(monday, 3),
          ),
          settings: const AppSettings(),
          on: Dates.addDays(monday, 10),
        )['state'],
        'outside',
      );
    });

    test('carries the natural key a mark can be replayed from', () {
      final List<Object?> classes = HomeWidgetPayload.day(
        engine: engineWith(
          records: <AttendanceRecord>[
            AttendanceRecord(
              subjectId: 1,
              date: monday,
              startMinutes: 9 * 60,
              status: AttendanceStatus.present,
            ),
          ],
        ),
        settings: const AppSettings(),
        on: monday,
      )['classes']! as List<Object?>;

      final Map<String, Object?> first = classes.single as Map<String, Object?>;
      expect(first['subjectId'], 1);
      expect(first['date'], 20260803);
      expect(first['startMinutes'], 9 * 60);
      expect(first['status'], 'present');
      expect(first['time'], '9:00 AM – 10:00 AM');
    });
  });

  group('the days written ahead for the launcher', () {
    test('each carries its own state, so midnight can move to the next', () {
      // From the Sunday before: a holiday on Monday, a plain Tuesday, and the
      // term over by Thursday.
      final List<Object?> days = HomeWidgetPayload.today(
        engine: engineWith(
          holidays: <Holiday>[Holiday(date: monday, name: 'Founders Day')],
          termEnd: Dates.addDays(monday, 2),
        ),
        settings: const AppSettings(),
        on: Dates.addDays(monday, -1),
      )['days']! as List<Object?>;

      final List<Map<String, Object?>> byDay =
          days.cast<Map<String, Object?>>();
      expect(byDay, hasLength(HomeWidgetPayload.daysAhead));
      expect(byDay.map((Map<String, Object?> d) => d['date']).take(4),
          <int>[20260802, 20260803, 20260804, 20260805]);
      expect(byDay[1]['state'], 'holiday');
      expect(byDay[2]['state'], 'empty');
      expect(byDay[4]['state'], 'outside');

      // The week columns follow the day across Monday.
      final List<Object?> weeks = HomeWidgetPayload.week(
        on: Dates.addDays(monday, -1),
      )['days']! as List<Object?>;
      expect((weeks[0]! as Map<String, Object?>)['monday'], 20260727);
      expect((weeks[1]! as Map<String, Object?>)['monday'], 20260803);
    });

    test('the next class moves on at each start and at midnight', () {
      final DateTime classDay = DateTime(2026, 10, 12);
      ExtraClass at(int hour) => ExtraClass(
            subjectId: 1,
            date: classDay,
            startMinutes: hour * 60,
            endMinutes: hour * 60 + 50,
          );
      final ScheduleEngine engine = ScheduleEngine(
        subjects: <Subject>[subject],
        slots: const <ClassSlot>[],
        extras: <ExtraClass>[at(9), at(11)],
        holidays: const <Holiday>[],
        records: const <AttendanceRecord>[],
      );
      List<Map<String, Object?>> upcomingAt(DateTime now) =>
          (HomeWidgetPayload.standing(
            upcoming: HomeWidgetPayload.upcoming(engine, now: now),
            stats: OverallStats(subjects: const <SubjectStats>[], target: 0.75),
            settings: const AppSettings(),
            now: now,
          )['upcoming']! as List<Object?>)
              .cast<Map<String, Object?>>();

      final List<Map<String, Object?>> evening =
          upcomingAt(DateTime(2026, 10, 11, 20));
      expect(
        evening.map((Map<String, Object?> c) => c['at']),
        <int>[
          DateTime(2026, 10, 12, 9).millisecondsSinceEpoch,
          DateTime(2026, 10, 12, 11).millisecondsSinceEpoch,
        ],
      );
      // Nothing for the day after the class, so the line goes rather than
      // naming a class that has already happened.
      expect(evening.first['when'], <String, String>{
        '20261011': 'Tomorrow, 9:00 AM',
        '20261012': 'Today, 9:00 AM',
      });

      // Once the 9:00 has started it is no longer offered.
      expect(
        upcomingAt(DateTime(2026, 10, 12, 9, 30))
            .map((Map<String, Object?> c) => c['at']),
        <int>[DateTime(2026, 10, 12, 11).millisecondsSinceEpoch],
      );
    });
  });

  test('the subject list puts the ones in trouble first', () {
    SubjectStats stat(String name, int present, int absent) => SubjectStats(
          subject: Subject(id: 1, name: name, colorValue: 0xFF7C6BFF),
          present: present,
          absent: absent,
          cancelled: 0,
          target: 0.75,
          plannedFromSlots: 10,
        );

    final Map<String, Object?> payload = HomeWidgetPayload.subjects(
      OverallStats(
        subjects: <SubjectStats>[
          stat('Untouched', 0, 0),
          stat('Comfortable', 9, 1),
          stat('Struggling', 1, 3),
        ],
        target: 0.75,
      ),
    );

    final List<Object?> rows = payload['subjects']! as List<Object?>;
    expect(
      rows.map((Object? r) => (r! as Map<String, Object?>)['name']),
      <String>['Struggling', 'Comfortable', 'Untouched'],
    );

    // A subject with nothing marked is untouched, not in trouble, so it sorts
    // last and shows no figure at all.
    final Map<String, Object?> untouched = rows.last as Map<String, Object?>;
    expect(untouched['percent'], isNull);
    expect(untouched['counts'], 'Nothing marked yet');

    final Map<String, Object?> worst = rows.first as Map<String, Object?>;
    expect(worst['percent'], 25);
    expect(worst['counts'], '1 of 4 attended');
    expect(worst['meetsTarget'], isFalse);
  });

  test('the standing repeats the home screen verdict word for word', () {
    final OverallStats stats = OverallStats(
      subjects: <SubjectStats>[
        SubjectStats(
          subject: subject,
          present: 3,
          absent: 1,
          cancelled: 0,
          target: 0.75,
          plannedFromSlots: 10,
        ),
      ],
      target: 0.75,
    );

    final Map<String, Object?> standing = HomeWidgetPayload.standing(
      upcoming: const <ClassSession>[],
      stats: stats,
      settings: const AppSettings(),
    );

    expect(standing['verdict'], stats.verdict);
    expect(standing['percent'], 75);
    expect(standing['meetsTarget'], isTrue);
  });

  group('the brightness the launcher draws in', () {
    testWidgets('follows the platform when the app is on System',
        (WidgetTester tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      expect(
        HomeWidgetPayload.widgetBrightness(const AppSettings()),
        Brightness.light,
      );

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      expect(
        HomeWidgetPayload.widgetBrightness(const AppSettings()),
        Brightness.dark,
      );
    });

    testWidgets('ignores the platform once the user has chosen',
        (WidgetTester tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      expect(
        HomeWidgetPayload.widgetBrightness(
          const AppSettings(themeMode: AppThemeMode.light),
        ),
        Brightness.light,
      );
    });
  });
}
