import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import 'package:zeolite/features/settings/settings_screen.dart';
import 'package:zeolite/features/settings/subjects_section.dart';
import 'package:zeolite/features/settings/timetable_layout_section.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/widgets/gradient_header.dart';

import 'slider_drag.dart';

/// Keeps what was saved instead of writing it, and serves it back the way the
/// real controller would.
class _RecordingSettings extends SettingsController {
  _RecordingSettings(this.initial, this.saved);

  final AppSettings initial;
  final List<AppSettings> saved;

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<void> save(AppSettings settings) async {
    saved.add(settings);
    state = AsyncData<AppSettings>(settings);
  }
}

const AppSettings _settings = AppSettings(
  onboarded: true,
  targetPercent: 75,
  defaultClassDurationMinutes: 60,
  dayStartMinutes: 9 * 60,
  dayEndMinutes: 17 * 60,
  blockMinutes: 60,
);

const TimetableData _empty = TimetableData(
  categories: <ClassCategory>[],
  subjects: <Subject>[],
  slots: <ClassSlot>[],
  extras: <ExtraClass>[],
  holidays: <Holiday>[],
  records: <AttendanceRecord>[],
);

Future<List<AppSettings>> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final List<AppSettings> saved = <AppSettings>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => _empty),
        settingsProvider
            .overrideWith(() => _RecordingSettings(_settings, saved)),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: child),
    ),
  );
  await tester.pumpAndSettle();
  return saved;
}

Widget _section(Widget section) => Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: section,
      ),
    );

Set<String> _texts(WidgetTester tester) => <String>{
      for (final Text text in tester.widgetList<Text>(find.byType(Text)))
        if (text.data != null) text.data!,
    };

void main() {
  group('Minimum required', () {
    testWidgets('the thumb follows the drag and the number is what is saved',
        (WidgetTester tester) async {
      final List<AppSettings> saved =
          await _pump(tester, const SettingsScreen());
      final Finder slider = find.byType(Slider);

      final (TestGesture drag, double finger) =
          await dragSlider(tester, slider, 120);
      expectThumbUnderFinger(tester, slider, finger, steps: 100);
      final String shown =
          tester.widget<HeaderNumber>(find.byType(HeaderNumber)).value;
      expect(saved, isEmpty);

      await drag.up();
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect('${saved.single.targetPercent.round()}', shown);
      expect(saved.single.targetPercent, saved.single.targetPercent.round());
    });

    testWidgets('one screen-reader increase is one percent, and saves',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final List<AppSettings> saved =
          await _pump(tester, const SettingsScreen());
      final Finder slider = find.byType(Slider);

      expect(adjustableNodes(tester), 1);
      adjustBySemantics(tester, slider, SemanticsAction.increase);
      await tester.pumpAndSettle();
      expect(saved, hasLength(1),
          reason: 'a screen-reader change should save, as a released drag '
              'does');
      expect(saved.last.targetPercent, 76);
      expect(
          tester.widget<HeaderNumber>(find.byType(HeaderNumber)).value, '76');

      adjustBySemantics(tester, slider, SemanticsAction.decrease);
      await tester.pumpAndSettle();
      expect(saved.last.targetPercent, 75);
      expect(saved, hasLength(2));
      handle.dispose();
    });
  });

  testWidgets('Minimum required runs from 0, and the lowest pick is 1',
      (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final List<AppSettings> saved = await _pump(tester, const SettingsScreen());
    final Finder slider = find.byType(Slider);
    String shown() =>
        tester.widget<HeaderNumber>(find.byType(HeaderNumber)).value;

    final double at75 = thumbX(tester, slider);
    final double at1 = await dragAndRelease(tester, slider, -4000);
    final String lowest = shown();
    final double lowestSaved = saved.last.targetPercent;
    final bool canGoLower = tester
        .getSemantics(slider)
        .getSemanticsData()
        .hasAction(SemanticsAction.decrease);
    final double at100 = await dragAndRelease(tester, slider, 4000);

    expectThreeQuarters(at1, at75, at100);
    expect(lowest, '1');
    expect(lowestSaved, 1);
    expect(canGoLower, isFalse, reason: 'a screen reader stops at 1 too');
    expect(shown(), '100');
    expect(saved.last.targetPercent, 100);
    handle.dispose();
  });

  testWidgets('Default class length follows the drag and saves what it shows',
      (WidgetTester tester) async {
    final List<AppSettings> saved =
        await _pump(tester, _section(const CategoriesSection()));
    final Finder slider = find.byType(Slider);

    final (TestGesture drag, double finger) =
        await dragSlider(tester, slider, 120);
    expectThumbUnderFinger(tester, slider, finger, steps: 57);
    final Set<String> shown = _texts(tester);

    await drag.up();
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(
        shown,
        contains(
            Clock.formatDuration(saved.single.defaultClassDurationMinutes)));
  });

  testWidgets('One block is follows the drag and saves what it shows',
      (WidgetTester tester) async {
    final List<AppSettings> saved =
        await _pump(tester, _section(const DayGridSection()));
    final Finder slider = find.byType(Slider).first;

    final (TestGesture drag, double finger) =
        await dragSlider(tester, slider, 120);
    expectThumbUnderFinger(tester, slider, finger, steps: 36);
    final Set<String> shown = _texts(tester);

    await drag.up();
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(shown, contains(Clock.formatDuration(saved.single.blockMinutes)));
  });

  testWidgets('Break follows the drag and saves what it shows',
      (WidgetTester tester) async {
    final List<AppSettings> saved =
        await _pump(tester, _section(const DayGridSection()));
    final Finder slider = find.byType(Slider).at(1);

    final (TestGesture drag, double finger) =
        await dragSlider(tester, slider, 120);
    expectThumbUnderFinger(tester, slider, finger, steps: 18);
    final Set<String> shown = _texts(tester);

    await drag.up();
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.breakMinutes, greaterThan(0));
    expect(shown, contains(Clock.formatDuration(saved.single.breakMinutes)));
  });
}
