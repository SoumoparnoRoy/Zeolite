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
import 'package:zeolite/data/models/room.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/models/tag.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/settings/settings_screen.dart';
import 'package:zeolite/features/stats/stats_screen.dart';
import 'package:zeolite/features/subjects/subjects_screen.dart';
import 'package:zeolite/features/timetable/timetable_screen.dart';
import 'package:zeolite/features/today/today_screen.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/widgets/common.dart';

/// The gradient headers and the seven-column grid are the two places this
/// layout can run out of width, and neither shows up in a logic test. These
/// pump every screen at the narrowest phone the app realistically sees, in
/// both themes, with the longest real course names — a RenderFlex overflow
/// fails the test.
const Size _smallPhone = Size(320, 640);

/// The tablet this is actually used on. Without a content cap the design just
/// stretches, so this checks the column is held to [GradientScaffold]'s width
/// rather than filling 1300px.
const Size _tablet = Size(1340, 2000);

const AppSettings _settings = AppSettings(
  onboarded: true,
  defaultClassDurationMinutes: 50,
  dayStartMinutes: 9 * 60,
  dayEndMinutes: 17 * 60,
  blockMinutes: 50,
);

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => _settings;
}

TimetableData _fixture() {
  final DateTime today = Dates.today();
  final DateTime monday = Dates.startOfWeek(today);
  return TimetableData(
    categories: const <ClassCategory>[
      ClassCategory(id: 1, name: 'Laboratory', defaultDurationMinutes: 100),
    ],
    rooms: const <Room>[Room(id: 1, name: 'B311A')],
    tags: const <Tag>[Tag(id: 1, name: 'Proxy')],
    subjects: const <Subject>[
      Subject(
        id: 1,
        name: 'Signals and Systems Laboratory Practical',
        code: 'ECE2104L',
        teacher: 'Dr A. Example',
        categoryId: 1,
        colorValue: 0xFF9BE36D,
      ),
      Subject(
        id: 2,
        name: 'Thermodynamics and Heat Transfer',
        code: 'MEC2205',
        teacher: 'Dr B. Example',
        colorValue: 0xFFFFB84D,
      ),
    ],
    slots: <ClassSlot>[
      for (int day = 1; day <= 5; day++)
        ClassSlot(
          id: day,
          subjectId: day.isEven ? 2 : 1,
          weekday: day,
          startMinutes: 9 * 60 + (day - 1) * 50,
          endMinutes: 9 * 60 + (day - 1) * 50 + 100,
          room: 'B311A',
          startDate: Dates.addDays(monday, -30),
        ),
    ],
    extras: <ExtraClass>[],
    holidays: const <Holiday>[],
    records: <AttendanceRecord>[
      AttendanceRecord(
        subjectId: 1,
        date: Dates.addDays(today, -7),
        startMinutes: 9 * 60,
        status: AttendanceStatus.present,
        tagId: 1,
      ),
      AttendanceRecord(
        subjectId: 2,
        date: Dates.addDays(today, -6),
        startMinutes: 9 * 60 + 50,
        status: AttendanceStatus.absent,
      ),
      AttendanceRecord(
        subjectId: 2,
        date: Dates.addDays(today, -5),
        startMinutes: 9 * 60 + 50,
        status: AttendanceStatus.cancelled,
      ),
    ],
  );
}

Widget _host(Widget screen, ThemeData theme, {double textScale = 1}) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => _fixture()),
      settingsProvider.overrideWith(_StaticSettings.new),
    ],
    child: MaterialApp(
      theme: theme,
      // copyWith, not a fresh MediaQueryData: replacing it wholesale zeroes
      // the size and padding the screens read for their own layout.
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: screen,
    ),
  );
}

void main() {
  final Map<String, Widget Function()> screens = <String, Widget Function()>{
    'Today': TodayScreen.new,
    'Timetable': TimetableScreen.new,
    'Stats': StatsScreen.new,
    'Settings': SettingsScreen.new,
    'Subjects': SubjectsScreen.new,
  };

  for (final MapEntry<String, Widget Function()> entry in screens.entries) {
    for (final MapEntry<String, ThemeData> theme in <String, ThemeData>{
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      testWidgets('${entry.key} lays out on a 320px phone in ${theme.key}',
          (WidgetTester tester) async {
        tester.view.physicalSize = _smallPhone;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_host(entry.value(), theme.value));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final MapEntry<String, Widget Function()> entry in screens.entries) {
    testWidgets('${entry.key} survives a larger system font',
        (WidgetTester tester) async {
      tester.view.physicalSize = _smallPhone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(entry.value(), AppTheme.light(), textScale: 1.3),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }

  for (final MapEntry<String, Widget Function()> entry in screens.entries) {
    testWidgets('${entry.key} lays out on a tablet with the scale ramp applied',
        (WidgetTester tester) async {
      tester.view.physicalSize = _tablet;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // The ramp grows the type, so it has to be exercised at tablet size or
      // the scaling is untested where it actually fires.
      await tester.pumpWidget(
        _host(
          entry.value(),
          AppTheme.light(),
          textScale: AppScale.of(_tablet),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }

  test('the scale ramp is continuous and flat on a phone', () {
    expect(AppScale.of(const Size(320, 640)), 1);
    expect(AppScale.of(const Size(600, 900)), 1);
    // Between the two ends it must be strictly between, not a step.
    final double mid = AppScale.of(const Size(750, 1100));
    expect(mid, greaterThan(1));
    expect(mid, lessThan(AppScale.of(const Size(900, 1400))));
    // And it stops climbing past the large end.
    expect(
      AppScale.of(const Size(2000, 2000)),
      AppScale.of(const Size(900, 1400)),
    );
  });

  testWidgets('a tablet gets a centred column, not a stretched phone',
      (WidgetTester tester) async {
    tester.view.physicalSize = _tablet;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const StatsScreen(), AppTheme.light()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // The gradient still bleeds edge to edge; the cards on the sheet do not.
    // The cap tracks AppScale, so assert against that rather than a constant
    // that would have to be chased every time the ramp is retuned.
    final double card = tester.getSize(find.byType(SurfaceCard).first).width;
    final double cap = AppScale.contentWidth(_tablet);
    expect(card, lessThanOrEqualTo(cap));
    expect(card, greaterThan(cap - 60));
    // Real gutters on both sides, not a full-bleed column.
    expect(card, lessThan(_tablet.width - 100));
  });

  testWidgets('the day rule add button keeps an accessible target',
      (WidgetTester tester) async {
    tester.view.physicalSize = _smallPhone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const TimetableScreen(), AppTheme.light()));
    await tester.pumpAndSettle();

    // The glyph is 16px so the rule stays a rule; the target must not be.
    final Size target = tester.getSize(
      find
          .ancestor(
            of: find.byIcon(Icons.add_rounded).first,
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(target.width, greaterThanOrEqualTo(44));
    expect(target.height, greaterThanOrEqualTo(44));
  });

  /// Height of one free block, measured off the empty cell's own box.
  Future<double> blockHeightAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(_host(const TodayScreen(), AppTheme.light()));
    await tester.pumpAndSettle();
    // The chosen view outlives a pump, so a second measurement is already on
    // the grid and has no toggle left to press.
    final Finder toggle = find.byTooltip('Show the week grid');
    if (toggle.evaluate().isNotEmpty) {
      await tester.tap(toggle);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    return tester
        .getSize(
          find
              .ancestor(
                of: find.byIcon(Icons.add_rounded).first,
                matching: find.byType(Material),
              )
              .first,
        )
        .height;
  }

  testWidgets('the week grid spends the height the screen actually has',
      (WidgetTester tester) async {
    addTearDown(tester.view.reset);

    final double shortScreen = await blockHeightAt(tester, _smallPhone);
    final double tallScreen =
        await blockHeightAt(tester, const Size(320, 1100));

    // Same width, more height: the blocks take the difference rather than
    // leaving it empty below the grid.
    expect(tallScreen, greaterThan(shortScreen));
  });

  testWidgets('a block is never squashed and never a slab',
      (WidgetTester tester) async {
    addTearDown(tester.view.reset);

    for (final Size size in <Size>[
      _smallPhone,
      const Size(320, 1100),
      const Size(600, 900),
      _tablet,
    ]) {
      final double block = await blockHeightAt(tester, size);
      final double scale = AppScale.of(size);
      expect(block, greaterThanOrEqualTo(46 * scale - 0.5),
          reason: 'too squashed at $size');
      expect(block, lessThanOrEqualTo(88 * scale + 0.5),
          reason: 'too tall at $size');
    }
  });

  testWidgets('the week grid fits all seven days without scrolling sideways',
      (WidgetTester tester) async {
    tester.view.physicalSize = _smallPhone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const TodayScreen(), AppTheme.light()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Show the week grid'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Monday through Sunday, all on screen at once.
    expect(find.text('S'), findsNWidgets(2));
  });
}
