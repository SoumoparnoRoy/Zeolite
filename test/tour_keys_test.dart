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
import 'package:zeolite/features/today/today_screen.dart';
import 'package:zeolite/features/tour/tour_stops.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

/// The timetable as the test sets it, standing in for adds and deletes.
class _Source extends Notifier<TimetableData> {
  @override
  TimetableData build() => _oneClass;

  void set(TimetableData data) => state = data;
}

final NotifierProvider<_Source, TimetableData> _source =
    NotifierProvider<_Source, TimetableData>(_Source.new);

final TimetableData _oneClass = TimetableData(
  categories: const <ClassCategory>[],
  subjects: const <Subject>[
    Subject(id: 1, name: 'Subject 1', colorValue: 0xFF6C4CF0),
  ],
  slots: <ClassSlot>[
    ClassSlot(
      id: 1,
      subjectId: 1,
      weekday: Dates.today().weekday,
      startMinutes: 9 * 60,
      endMinutes: 10 * 60,
      startDate: Dates.addDays(Dates.today(), -7),
    ),
  ],
  extras: const <ExtraClass>[],
  holidays: const <Holiday>[],
  records: const <AttendanceRecord>[],
);

const TimetableData _empty = TimetableData(
  categories: <ClassCategory>[],
  subjects: <Subject>[],
  slots: <ClassSlot>[],
  extras: <ExtraClass>[],
  holidays: <Holiday>[],
  records: <AttendanceRecord>[],
);

void main() {
  // Scaffold keeps a FAB that is going away on screen while it shrinks, and
  // the empty state's button arrives in that same frame. Sharing one key,
  // the two were briefly the same GlobalKey in two places.
  testWidgets('deleting the last class keeps each tour key in one place',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        timetableProvider.overrideWith(
          (Ref ref) async => ref.watch(_source),
        ),
        settingsProvider.overrideWith(_StaticSettings.new),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: const TodayScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Add class'), findsOneWidget);
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(TodayScreen)));

    container.read(_source.notifier).set(_empty);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();

    expect(find.text('Add your first class'), findsOneWidget);
    final TourTargets targets = container.read(tourTargetsProvider);
    expect(
      targets.keyFor(TourTarget.addClass).currentContext,
      isNotNull,
      reason: 'the empty state carries the first stop',
    );
  });
}
