import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/domain/term_outlook.dart';
import 'package:zeolite/features/stats/plan_page.dart';
import 'package:zeolite/features/today/session_card.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

class _FailingSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => throw StateError('unreadable');
}

TimetableData _withTotal(
  int? expectedTotal, {
  int attended = 16,
  bool withUntotalled = false,
}) =>
    TimetableData(
      categories: const <ClassCategory>[],
      subjects: <Subject>[
        Subject(
          id: 1,
          name: 'Course 1',
          colorValue: AppColors.defaultSubjectColor,
          priorHeld: 20,
          priorAttended: attended,
          expectedTotal: expectedTotal,
        ),
        if (withUntotalled)
          const Subject(
            id: 2,
            name: 'Course 2',
            colorValue: AppColors.defaultSubjectColor,
            priorHeld: 10,
            priorAttended: 9,
          ),
      ],
      slots: const <ClassSlot>[],
      extras: const <ExtraClass>[],
      holidays: const <Holiday>[],
      records: const <AttendanceRecord>[],
    );

Future<void> _pumpPlan(
  WidgetTester tester,
  TimetableData data, {
  SettingsController Function() settings = _StaticSettings.new,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => data),
        settingsProvider.overrideWith(settings),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: PlanPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const Subject _course = Subject(
  id: 1,
  name: 'Course 1',
  colorValue: AppColors.defaultSubjectColor,
  expectedTotal: 40,
);

final TermOutlook _outlook = TermOutlook.of(
  const SubjectStats(
    subject: _course,
    present: 16,
    absent: 4,
    cancelled: 0,
    target: 0.75,
    plannedFromSlots: 0,
  ),
  termEndKnown: true,
)!;

Future<void> _pumpCard(WidgetTester tester, ClassSession session) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SessionCard(
            session: session,
            onMark: (_) {},
            use24Hour: true,
            outlook: _outlook,
          ),
        ),
      ),
    ),
  );
}

ClassSession _tomorrow({AttendanceStatus? status}) {
  final DateTime now = DateTime.now();
  final DateTime date = DateTime(now.year, now.month, now.day + 1);
  return ClassSession(
    subject: _course,
    date: date,
    startMinutes: 540,
    endMinutes: 600,
    slotId: 1,
    record: status == null
        ? null
        : AttendanceRecord(
            subjectId: 1,
            date: date,
            startMinutes: 540,
            status: status,
          ),
  );
}

void main() {
  group('the Plan view', () {
    testWidgets('asks for term dates when it cannot see the end of the term',
        (WidgetTester tester) async {
      await _pumpPlan(tester, _withTotal(null));
      expect(find.text('Set term dates to plan'), findsOneWidget);
      expect(find.textContaining('Skip budget'), findsNothing);
    });

    testWidgets('a subject with a term total gets its budget',
        (WidgetTester tester) async {
      await _pumpPlan(tester, _withTotal(40));
      expect(find.text('Skip budget this term: 6 classes'), findsOneWidget);
      expect(find.text('20 classes left this term'), findsOneWidget);
      expect(find.text('Finishes between 75.00% and 90.00%'), findsOneWidget);
      expect(find.text('20 classes left · target 75%'), findsOneWidget);
    });

    testWidgets(
        'a best finish just short of the target is not rounded up to it',
        (WidgetTester tester) async {
      // 1 of 20 so far and 55 left of 75: 56 of 75 at best, 74.7%.
      await _pumpPlan(tester, _withTotal(75, attended: 1));
      expect(find.text('Target is out of reach this term'), findsOneWidget);
      expect(find.text('Best finish 74.66%'), findsOneWidget);
    });

    testWidgets('says which subjects it could not count, and why no list',
        (WidgetTester tester) async {
      await _pumpPlan(tester, _withTotal(40, withUntotalled: true));
      expect(find.text('Skip budget this term: 6 classes'), findsOneWidget);
      expect(
        find.text('One subject without a term total is not counted here.'),
        findsOneWidget,
      );
      expect(
        find.text("Add the term's end date in Settings to list the classes "
            'ahead.'),
        findsOneWidget,
      );
    });

    testWidgets('settings that fail to load are not mistaken for no term',
        (WidgetTester tester) async {
      await _pumpPlan(tester, _withTotal(null), settings: _FailingSettings.new);
      expect(find.text('Could not load your data'), findsOneWidget);
      expect(find.text('Set term dates to plan'), findsNothing);
    });
  });

  group('a class on Today', () {
    testWidgets('still to come shows its subject budget',
        (WidgetTester tester) async {
      await _pumpCard(tester, _tomorrow());
      expect(find.text('Skip budget this term: 6 classes'), findsOneWidget);
    });

    testWidgets('once marked no longer does', (WidgetTester tester) async {
      await _pumpCard(tester, _tomorrow(status: AttendanceStatus.present));
      expect(find.textContaining('Skip budget'), findsNothing);
    });
  });
}
