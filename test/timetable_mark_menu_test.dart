import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/timetable/timetable_screen.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_analytics.dart';
import 'fake_notifications.dart';

/// Records what the menu asked the database to do.
class _Recording extends ZeoliteRepository {
  final List<AttendanceRecord> set = <AttendanceRecord>[];
  final List<int> cleared = <int>[];

  @override
  Future<DatabaseSnapshot> snapshot() async =>
      <String, List<Map<String, Object?>>>{};

  @override
  Future<AttendanceRecord?> getAttendanceAt(
    int subjectId,
    DateTime date,
    int startMinutes,
  ) async =>
      null;

  @override
  Future<void> setAttendance(AttendanceRecord record) async => set.add(record);

  @override
  Future<void> clearAttendance(
    int subjectId,
    DateTime date,
    int startMinutes,
  ) async =>
      cleared.add(startMinutes);
}

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

final DateTime _monday = Dates.startOfWeek(Dates.today());

TimetableData _week() => TimetableData(
      categories: const <ClassCategory>[],
      subjects: const <Subject>[
        Subject(id: 1, name: 'Course 1', colorValue: 0xFF336699),
      ],
      slots: <ClassSlot>[
        ClassSlot(
          id: 1,
          subjectId: 1,
          weekday: 1,
          startMinutes: 9 * 60,
          endMinutes: 10 * 60,
          weight: 2,
          startDate: Dates.addDays(_monday, -14),
        ),
      ],
      extras: const <ExtraClass>[],
      holidays: const <Holiday>[],
      records: <AttendanceRecord>[
        AttendanceRecord(
          subjectId: 1,
          date: _monday,
          startMinutes: 9 * 60,
          status: AttendanceStatus.present,
          weight: 2,
        ),
      ],
    );

Future<_Recording> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Recording repo = _Recording();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        notificationsProvider.overrideWithValue(QuietNotifications()),
        analyticsProvider.overrideWithValue(FakeAnalytics()),
        timetableProvider.overrideWith((Ref ref) async => _week()),
        settingsProvider.overrideWith(_StaticSettings.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const TimetableScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('a tap offers the statuses and changes the mark',
      (WidgetTester tester) async {
    final _Recording repo = await _pump(tester);

    await tester.tap(find.text('Course 1'));
    await tester.pumpAndSettle();
    // The current status is filled in, and a marked class can be cleared.
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
    expect(find.text('Clear the mark'), findsOneWidget);

    await tester.tap(find.text('Absent').last);
    await tester.pumpAndSettle();
    final AttendanceRecord written = repo.set.single;
    expect(written.status, AttendanceStatus.absent);
    expect(written.weight, 2);
    expect(repo.cleared, isEmpty);
  });

  testWidgets('picking the status it already has leaves the mark alone',
      (WidgetTester tester) async {
    final _Recording repo = await _pump(tester);

    await tester.tap(find.text('Course 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Present').last);
    await tester.pumpAndSettle();

    expect(repo.set, isEmpty);
    expect(repo.cleared, isEmpty);
  });

  testWidgets('clearing from the menu offers it back',
      (WidgetTester tester) async {
    final _Recording repo = await _pump(tester);

    await tester.tap(find.text('Course 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear the mark'));
    await tester.pumpAndSettle();

    expect(repo.cleared, <int>[9 * 60]);
    expect(find.text('Mark cleared'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('a long press edits the class and leaves marking to the tap',
      (WidgetTester tester) async {
    await _pump(tester);

    await tester.longPress(find.text('Course 1'));
    await tester.pumpAndSettle();

    expect(find.text('Edit the weekly class'), findsOneWidget);
    expect(find.text('Clear the mark'), findsNothing);
  });

  testWidgets('each day is headed with its full date',
      (WidgetTester tester) async {
    await _pump(tester);

    expect(
      find.textContaining(
        '${Dates.weekdayShort(_monday)} ${Dates.formatFull(_monday)}'
            .toUpperCase(),
      ),
      findsOneWidget,
    );
  });
}
