import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/subjects/subjects_screen.dart';
import 'package:zeolite/state/providers.dart';

/// Serves fixed settings so the screen never reaches SharedPreferences.
class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

/// Physics: a code, a category, 2 weekly classes, 1 one-off and 4 marks
/// (3 present of 4 held = 75%). Maths: bare, nothing recorded.
TimetableData _fixture() {
  final DateTime day = Dates.today();
  return TimetableData(
    categories: const <ClassCategory>[
      ClassCategory(id: 1, name: 'Lab', defaultDurationMinutes: 120),
    ],
    subjects: const <Subject>[
      Subject(
        id: 2,
        name: 'Mathematics',
        colorValue: AppColors.defaultSubjectColor,
      ),
      Subject(
        id: 1,
        name: 'Physics',
        code: 'PH101',
        categoryId: 1,
        colorValue: AppColors.defaultSubjectColor,
      ),
    ],
    slots: <ClassSlot>[
      ClassSlot(
        id: 1,
        subjectId: 1,
        weekday: DateTime.monday,
        startMinutes: 9 * 60,
        endMinutes: 11 * 60,
        startDate: day,
      ),
      ClassSlot(
        id: 2,
        subjectId: 1,
        weekday: DateTime.wednesday,
        startMinutes: 9 * 60,
        endMinutes: 11 * 60,
        startDate: day,
      ),
    ],
    extras: <ExtraClass>[
      ExtraClass(
        id: 1,
        subjectId: 1,
        date: day,
        startMinutes: 14 * 60,
        endMinutes: 15 * 60,
      ),
    ],
    holidays: const <Holiday>[],
    records: <AttendanceRecord>[
      for (int i = 0; i < 3; i++)
        AttendanceRecord(
          subjectId: 1,
          date: Dates.addDays(day, -i),
          startMinutes: 9 * 60,
          status: AttendanceStatus.present,
        ),
      AttendanceRecord(
        subjectId: 1,
        date: Dates.addDays(day, -3),
        startMinutes: 9 * 60,
        status: AttendanceStatus.absent,
      ),
    ],
  );
}

Widget _app(TimetableData data) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => data),
      settingsProvider.overrideWith(_StaticSettings.new),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: const SubjectsScreen(),
    ),
  );
}

void main() {
  testWidgets('leads each subject with its code, and totals in the header',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    expect(find.text('Subjects'), findsOneWidget);
    expect(find.text('Physics'), findsOneWidget);
    expect(find.text('Mathematics'), findsOneWidget);

    // The code leads, in mono, so a theory course and its lab stop reading as
    // duplicates of each other. Per-subject counts moved to the header.
    expect(find.text('PH101 · LAB'), findsOneWidget);
    // Two weekly slots; the one-off is not a weekly class.
    expect(find.text('2 courses · 2 weekly classes'), findsOneWidget);
    // Nothing scheduled is the one count still worth saying inline.
    expect(find.text('no classes'), findsOneWidget);

    expect(find.text('75%'), findsOneWidget); // 3 present of 4 held
    expect(find.text('—'), findsOneWidget); // Mathematics, nothing marked
    expect(find.text('Add subject'), findsOneWidget);
  });

  testWidgets('shows the empty state when there are no subjects',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const TimetableData(
          categories: <ClassCategory>[],
          subjects: <Subject>[],
          slots: <ClassSlot>[],
          extras: <ExtraClass>[],
          holidays: <Holiday>[],
          records: <AttendanceRecord>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No subjects yet'), findsOneWidget);
    expect(find.text('Add your first subject'), findsOneWidget);
    // The FAB would duplicate the empty state's own call to action.
    expect(find.text('Add subject'), findsNothing);
  });

  testWidgets('the delete dialog spells out exactly what is lost',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    // Physics sorts after Mathematics, so its menu is the second one.
    await tester.tap(find.byIcon(Icons.more_vert_rounded).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Physics?'), findsOneWidget);
    expect(
      find.textContaining(
        'Physics has 2 weekly classes, 1 one-off class and 4 attendance marks.',
      ),
      findsOneWidget,
    );

    // Cancelling must not touch the data layer.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Physics'), findsOneWidget);
  });

  testWidgets('a carried balance counts among what a delete loses',
      (WidgetTester tester) async {
    final TimetableData data = _fixture();
    await tester.pumpWidget(
      _app(
        TimetableData(
          categories: data.categories,
          subjects: <Subject>[
            const Subject(
              id: 2,
              name: 'Mathematics',
              colorValue: AppColors.defaultSubjectColor,
              priorHeld: 16,
              priorAttended: 14,
            ),
          ],
          slots: const <ClassSlot>[],
          extras: const <ExtraClass>[],
          holidays: const <Holiday>[],
          records: const <AttendanceRecord>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Nothing is a record, but 16 classes are still on the subject.
    expect(
      find.textContaining('Mathematics has 14 of 16 carried in.'),
      findsOneWidget,
    );
    expect(find.textContaining('nothing else is lost'), findsNothing);
  });

  testWidgets('a subject with no classes counts by hand',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const TimetableData(
          categories: <ClassCategory>[],
          subjects: <Subject>[
            Subject(
              id: 2,
              name: 'Mathematics',
              colorValue: AppColors.defaultSubjectColor,
              priorHeld: 4,
              priorAttended: 3,
            ),
          ],
          slots: <ClassSlot>[],
          extras: <ExtraClass>[],
          holidays: <Holiday>[],
          records: <AttendanceRecord>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3 of 4 attended'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
  });
}
