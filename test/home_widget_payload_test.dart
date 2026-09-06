import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
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
  List<Holiday> holidays = const <Holiday>[],
  List<AttendanceRecord> records = const <AttendanceRecord>[],
  DateTime? semesterStart,
  DateTime? semesterEnd,
}) =>
    ScheduleEngine(
      subjects: <Subject>[subject],
      slots: <ClassSlot>[slot()],
      extras: const <ExtraClass>[],
      holidays: holidays,
      records: records,
      semesterStart: semesterStart,
      semesterEnd: semesterEnd,
    );

void main() {
  group('the day the widget is told about', () {
    test('names the four states apart rather than sending an empty list', () {
      expect(
        HomeWidgetPayload.today(
          engine: engineWith(),
          settings: const AppSettings(),
          on: monday,
        )['state'],
        'classes',
      );

      // Tuesday: the rule does not apply, but the term is running.
      expect(
        HomeWidgetPayload.today(
          engine: engineWith(),
          settings: const AppSettings(),
          on: Dates.addDays(monday, 1),
        )['state'],
        'empty',
      );

      final Map<String, Object?> holiday = HomeWidgetPayload.today(
        engine: engineWith(
          holidays: <Holiday>[Holiday(date: monday, name: 'Founders Day')],
        ),
        settings: const AppSettings(),
        on: monday,
      );
      expect(holiday['state'], 'holiday');
      expect(holiday['holiday'], 'Founders Day');

      expect(
        HomeWidgetPayload.today(
          engine: engineWith(
            semesterStart: monday,
            semesterEnd: Dates.addDays(monday, 3),
          ),
          settings: const AppSettings(),
          on: Dates.addDays(monday, 10),
        )['state'],
        'outside',
      );
    });

    test('carries the natural key a mark can be replayed from', () {
      final List<Object?> classes = HomeWidgetPayload.today(
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
      engine: engineWith(),
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
