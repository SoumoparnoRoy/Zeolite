import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/domain/schedule_engine.dart';
import 'package:zeolite/features/today/today_screen.dart';
import 'package:zeolite/state/providers.dart';

/// A Monday with a 09:00–10:00 class every week of the term.
final DateTime monday = DateTime(2026, 8, 3);
final DateTime termEnd = Dates.addDays(monday, 21);

const Subject _course = Subject(
  id: 1,
  name: 'Course 1',
  colorValue: AppColors.defaultSubjectColor,
);

final ClassSlot _slot = ClassSlot(
  id: 1,
  subjectId: 1,
  weekday: DateTime.monday,
  startMinutes: 9 * 60,
  endMinutes: 10 * 60,
  startDate: Dates.addDays(monday, -70),
);

final TimetableData _timetable = TimetableData(
  categories: const <ClassCategory>[],
  subjects: const <Subject>[_course],
  slots: <ClassSlot>[_slot],
  extras: const <ExtraClass>[],
  holidays: const <Holiday>[],
  records: const <AttendanceRecord>[],
);

DateTime _on(int hour, int minute) =>
    DateTime(monday.year, monday.month, monday.day, hour, minute);

class _Term extends SettingsController {
  @override
  Future<AppSettings> build() async => AppSettings(
        onboarded: true,
        termStart: Dates.addDays(monday, -70),
        termEnd: termEnd,
      );
}

/// Moved by the test instead of by timers.
class _HeldClock extends ClockController {
  _HeldClock(this._start);

  final DateTime _start;

  @override
  DateTime build() => _start;

  void set(DateTime now) => state = now;
}

void main() {
  group('the next moment a screen changes', () {
    final ScheduleEngine engine = ScheduleEngine(
      subjects: const <Subject>[_course],
      slots: <ClassSlot>[_slot],
      extras: const <ExtraClass>[],
      holidays: const <Holiday>[],
      records: const <AttendanceRecord>[],
      overrides: const [],
      termEnd: termEnd,
    );

    test('is the class starting, then the class ending', () {
      expect(engine.nextChange(_on(8, 0)), _on(9, 0));
      expect(engine.nextChange(_on(9, 30)), _on(10, 0));
    });

    test('is midnight once the day has nothing left to start or end', () {
      expect(engine.nextChange(_on(10, 30)), Dates.addDays(monday, 1));
      expect(
        engine.nextChange(Dates.addDays(monday, 1)),
        Dates.addDays(monday, 2),
      );
    });
  });

  test('a class stays in the plan and the count until it ends', () async {
    final _HeldClock clock = _HeldClock(_on(8, 30));
    final ProviderContainer container = ProviderContainer(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => _timetable),
        settingsProvider.overrideWith(_Term.new),
        clockProvider.overrideWith(() => clock),
      ],
    );
    addTearDown(container.dispose);
    await container.read(timetableProvider.future);
    await container.read(settingsProvider.future);

    int remaining() => container
        .read(statsProvider)
        .subjects
        .singleWhere((SubjectStats s) => s.subject.id == 1)
        .remainingPlanned;
    List<DateTime> ahead() => <DateTime>[
          for (final ClassSession s in container.read(classesAheadProvider))
            s.date,
        ];

    expect(remaining(), 4);
    expect(ahead(), hasLength(4));
    expect(ahead().first, monday);

    clock.set(_on(9, 30));
    expect(remaining(), 4);
    expect(ahead().first, monday);

    clock.set(_on(10, 30));
    expect(remaining(), 3);
    expect(ahead(), hasLength(3));
    expect(ahead().first, Dates.addDays(monday, 7));
  });

  test("today's dot in the date strip appears as its class ends", () async {
    final _HeldClock clock = _HeldClock(_on(9, 30));
    final ProviderContainer container = ProviderContainer(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => _timetable),
        settingsProvider.overrideWith(_Term.new),
        clockProvider.overrideWith(() => clock),
      ],
    );
    addTearDown(container.dispose);
    await container.read(timetableProvider.future);
    await container.read(settingsProvider.future);

    bool waiting() =>
        container.read(dayMarkersProvider)[Dates.keyOf(monday)]!.hasUnmarked;

    expect(waiting(), isFalse);
    clock.set(_on(10, 30));
    expect(waiting(), isTrue);
  });

  testWidgets('the clock moves on by itself when a class starts',
      (WidgetTester tester) async {
    // Real time, since the controller reads it; the timer is the test's.
    final DateTime now = DateTime.now();
    // Near midnight the day's own boundary comes first and the one-off would
    // run past the end of the day, so there is nothing to tell apart.
    if (Dates.addDays(Dates.dayOf(now), 1).difference(now) <
        const Duration(minutes: 5)) {
      return;
    }
    final DateTime start = now.add(const Duration(minutes: 2));
    final int startMinutes = start.hour * 60 + start.minute;
    final ProviderContainer container = ProviderContainer(
      overrides: [
        timetableProvider.overrideWith(
          (Ref ref) async => TimetableData(
            categories: const <ClassCategory>[],
            subjects: const <Subject>[_course],
            slots: const <ClassSlot>[],
            extras: <ExtraClass>[
              ExtraClass(
                id: 1,
                subjectId: 1,
                date: Dates.dayOf(start),
                startMinutes: startMinutes,
                endMinutes: startMinutes + 1,
              ),
            ],
            holidays: const <Holiday>[],
            records: const <AttendanceRecord>[],
          ),
        ),
        settingsProvider.overrideWith(_Term.new),
      ],
    );
    int ticks = 0;
    container.listen<DateTime>(clockProvider, (_, __) => ticks++);
    await tester.runAsync(() => container.read(timetableProvider.future));
    container.read(scheduleEngineProvider);

    await tester.pump(const Duration(seconds: 30));
    expect(ticks, 0);
    await tester.pump(const Duration(minutes: 3));
    expect(ticks, greaterThan(0));
    // Here, not in a tear-down: the midnight timer is still pending.
    container.dispose();
  });
}
