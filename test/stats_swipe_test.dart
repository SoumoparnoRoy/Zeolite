import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/stats/stats_screen.dart';
import 'package:zeolite/features/stats/stats_view.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/widgets/pager_handoff.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

const TimetableData _one = TimetableData(
  categories: <ClassCategory>[],
  subjects: <Subject>[
    Subject(
      id: 1,
      name: 'Course 1',
      colorValue: AppColors.defaultSubjectColor,
      priorHeld: 10,
      priorAttended: 8,
    ),
  ],
  slots: <ClassSlot>[],
  extras: <ExtraClass>[],
  holidays: <Holiday>[],
  records: <AttendanceRecord>[],
);

/// Stats between two stand-in tabs, as the shell's pager holds it.
Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => _one),
        settingsProvider.overrideWith(_StaticSettings.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: PageView(
          controller: PageController(initialPage: 1),
          children: const <Widget>[
            Center(child: Text('Tab before')),
            StatsScreen(),
            Center(child: Text('Tab after')),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final Finder _header = find.text('ATTENDANCE · THIS TERM');
final Finder _overview = find.text('BY SUBJECT');
final Finder _counts = find.text('Update from a portal photo');

void main() {
  group('splitting one movement', () {
    test('the inner pager takes it until its edge, the rest goes on', () {
      expect(
        PagerHandoff.split(
          delta: 50,
          outerOffset: 0,
          innerPixels: 0,
          innerMin: 0,
          innerMax: 400,
        ),
        (50.0, 0.0),
      );
      expect(
        PagerHandoff.split(
          delta: 50,
          outerOffset: 0,
          innerPixels: 380,
          innerMin: 0,
          innerMax: 400,
        ),
        (20.0, 30.0),
      );
    });

    test('an outer pager pulled off its page goes back before the inner moves',
        () {
      expect(
        PagerHandoff.split(
          delta: -50,
          outerOffset: 30,
          innerPixels: 400,
          innerMin: 0,
          innerMax: 400,
        ),
        (-20.0, -30.0),
      );
      expect(
        PagerHandoff.split(
          delta: 10,
          outerOffset: 30,
          innerPixels: 400,
          innerMin: 0,
          innerMax: 400,
        ),
        (0.0, 10.0),
      );
    });
  });

  testWidgets('swiping between the views moves the pages, not the header',
      (WidgetTester tester) async {
    await _pump(tester);
    final Offset headerAt = tester.getTopLeft(_header);
    final Offset listAt = tester.getTopLeft(_overview);

    final TestGesture drag =
        await tester.startGesture(tester.getCenter(_overview));
    await drag.moveBy(const Offset(-40, 0));
    await drag.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(tester.getTopLeft(_header), headerAt);
    expect(tester.getTopLeft(_overview).dx, lessThan(listAt.dx - 100));

    // Past halfway, so it settles on Counts without a fling.
    await drag.moveBy(const Offset(-80, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(_counts, findsOneWidget);
    expect(tester.getTopLeft(_header), headerAt);
  });

  testWidgets('another screen can open Stats on Counts',
      (WidgetTester tester) async {
    await _pump(tester);
    ProviderScope.containerOf(tester.element(find.byType(StatsScreen)))
        .read(statsViewProvider.notifier)
        .show(StatsView.counts);
    await tester.pumpAndSettle();

    expect(_counts, findsOneWidget);
  });

  testWidgets('past the first view, the same swipe reaches the tab before',
      (WidgetTester tester) async {
    await _pump(tester);

    // Short of halfway: only the fling's speed can carry it there.
    await tester.fling(_overview, const Offset(120, 0), 2000);
    await tester.pumpAndSettle();

    expect(find.text('Tab before'), findsOneWidget);
  });

  testWidgets('past the last view, the same swipe reaches the tab after',
      (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(find.text('Counts'));
    await tester.pumpAndSettle();

    await tester.fling(_counts, const Offset(-120, 0), 2000);
    await tester.pumpAndSettle();

    expect(find.text('Tab after'), findsOneWidget);
  });
}
