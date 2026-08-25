import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/timetable/week_grid_view.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  _StaticSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

/// 9:00–17:00 on 50-minute blocks — nine blocks, so a Lab of two of them is
/// 1h 40m and lands on 9:00–10:40.
const AppSettings _settings = AppSettings(
  onboarded: true,
  defaultClassDurationMinutes: 50,
  dayStartMinutes: 9 * 60,
  dayEndMinutes: 17 * 60,
  blockMinutes: 50,
);

/// The same day with a 40-minute break after the fourth block, which puts it
/// at 12:20 and pushes the afternoon to 13:00.
const AppSettings _withBreak = AppSettings(
  onboarded: true,
  defaultClassDurationMinutes: 50,
  dayStartMinutes: 9 * 60,
  dayEndMinutes: 17 * 60,
  blockMinutes: 50,
  breakAfterBlock: 4,
  breakMinutes: 40,
);

TimetableData _fixture({
  List<ClassSlot> slots = const <ClassSlot>[],
  List<Holiday> holidays = const <Holiday>[],
}) =>
    TimetableData(
      categories: const <ClassCategory>[
        ClassCategory(id: 1, name: 'Lab', defaultDurationMinutes: 100),
      ],
      subjects: const <Subject>[
        Subject(
          id: 1,
          name: 'Physics',
          teacher: 'Dr A. Example',
          categoryId: 1,
          colorValue: AppColors.defaultSubjectColor,
        ),
      ],
      slots: slots,
      extras: <ExtraClass>[],
      holidays: holidays,
      records: <AttendanceRecord>[],
    );

Widget _app(TimetableData data, {AppSettings settings = _settings}) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => data),
      settingsProvider.overrideWith(() => _StaticSettings(settings)),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: WeekGridView(weekStart: Dates.startOfWeek(Dates.today())),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a break is drawn as a labelled row across the grid',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture(), settings: _withBreak));
    await tester.pumpAndSettle();

    expect(find.textContaining('Break'), findsOneWidget);
    expect(find.textContaining('12:20 pm – 1:00 pm'), findsOneWidget);

    final double grid = tester.getSize(find.byType(WeekGridView)).width;
    final Finder band = find
        .ancestor(
          of: find.textContaining('Break'),
          matching: find.byType(Container),
        )
        .first;
    expect(tester.getSize(band).width, closeTo(grid, 0.5));
  });

  testWidgets('no break, no row', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Break'), findsNothing);
  });

  testWidgets('the afternoon still starts where the break left off',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture(), settings: _withBreak));
    await tester.pumpAndSettle();

    // Four blocks before it, and the first one after starts at 13:00 rather
    // than carrying on from noon.
    expect(find.text('9:00'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);
  });

  testWidgets('a holiday is named in the grid, not left blank',
      (WidgetTester tester) async {
    final DateTime monday = Dates.startOfWeek(Dates.today());
    await tester.pumpWidget(
      _app(
        _fixture(
          slots: <ClassSlot>[
            ClassSlot(
              id: 1,
              subjectId: 1,
              weekday: DateTime.monday,
              startMinutes: 9 * 60,
              endMinutes: 10 * 60,
              startDate: Dates.addDays(monday, -30),
            ),
          ],
          holidays: <Holiday>[Holiday(date: monday, name: 'Founders Day')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The recurring class is gone, as it should be — but the day says why.
    expect(find.text('PH'), findsNothing);
    expect(find.text('Founders Day'), findsOneWidget);
  });

  testWidgets('a one-off class on a holiday still shows',
      (WidgetTester tester) async {
    final DateTime monday = Dates.startOfWeek(Dates.today());
    await tester.pumpWidget(
      _app(
        _fixture(holidays: <Holiday>[Holiday(date: monday, name: 'Rest day')]),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing recurring, so the whole column is the holiday panel, named once
    // rather than once per free block.
    expect(find.text('Rest day'), findsOneWidget);
  });

  testWidgets('lays out one row per block', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    // Nine whole blocks and the short 30-minute tail, across seven days, all
    // of them free.
    expect(find.byIcon(Icons.add_rounded), findsNWidgets(10 * 7));
    // The gutter keeps the minutes — without them a sub-hourly block length
    // prints the same label twice in a row.
    expect(find.text('9:00'), findsOneWidget);
    expect(find.text('9:50'), findsOneWidget);
    expect(find.text('3:40'), findsOneWidget);
    expect(find.text('4:30'), findsOneWidget);
  });

  testWidgets('each empty cell opens its own block, not the last one',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    // Regression: the cell callbacks used to close over the loop variable, so
    // every cell in the column reported the index the loop finished on.
    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('Monday · block 1'), findsOneWidget);
    expect(find.text('9:00 am – 9:50 am'), findsOneWidget);
  });

  testWidgets('a two-block class is twice the height of an empty cell',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        _fixture(
          slots: <ClassSlot>[
            ClassSlot(
              id: 1,
              subjectId: 1,
              weekday: DateTime.monday,
              startMinutes: 9 * 60,
              endMinutes: 9 * 60 + 100,
              room: 'PHY-LAB',
              startDate: Dates.addDays(Dates.today(), -30),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Seven columns have to fit the screen, so a tile carries the subject's
    // code rather than its name.
    expect(find.text('PH'), findsOneWidget);
    expect(find.text('PHY-LAB'), findsOneWidget);

    // Two blocks plus the gap between them, measured against a free block
    // rather than a fixed number so a change of block height cannot silently
    // break the ratio this test exists to guard.
    final double blockHeight = tester
        .getSize(
          find
              .ancestor(
                of: find.byIcon(Icons.add_rounded),
                matching: find.byType(Material),
              )
              .first,
        )
        .height;
    final Finder tile = find.ancestor(
      of: find.text('PH'),
      matching: find.byType(Material),
    );
    expect(
      tester.getSize(tile.first).height,
      closeTo(blockHeight * 2 + 4, 0.5),
    );
  });

  testWidgets('a class off the block boundary shows its real time',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        _fixture(
          slots: <ClassSlot>[
            ClassSlot(
              id: 1,
              subjectId: 1,
              weekday: DateTime.monday,
              // 9:30 is inside block 1 but not on its edge.
              startMinutes: 9 * 60 + 30,
              endMinutes: 10 * 60 + 30,
              startDate: Dates.addDays(Dates.today(), -30),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Flagged rather than silently drawn as if it started at 9:00.
    expect(find.text('9:30 am'), findsOneWidget);
  });

  testWidgets('without a block length the grid explains itself instead',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        _fixture(),
        settings: const AppSettings(onboarded: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Divide your day up first'), findsOneWidget);
  });
}
