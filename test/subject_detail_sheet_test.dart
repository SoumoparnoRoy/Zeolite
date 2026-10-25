import 'dart:async';

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
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/features/stats/subject_detail_sheet.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

/// A delete that doesn't finish until [gate] does.
class _HeldDelete extends SubjectActions {
  _HeldDelete(super.core, this.gate);

  final Completer<void> gate;

  @override
  Future<void> deleteSubject(int id) => gate.future;
}

const Subject _physics = Subject(
  id: 1,
  name: 'Physics',
  colorValue: AppColors.defaultSubjectColor,
);

class _PushCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

Widget _app(
  Completer<void> gate, {
  Subject subject = _physics,
  NavigatorObserver? observer,
}) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith(
        // Classes to name make the dialog's message long enough that its
        // buttons land over the sheet's.
        (Ref ref) async => TimetableData(
          categories: const <ClassCategory>[],
          subjects: <Subject>[subject],
          slots: <ClassSlot>[
            for (int day = 1; day <= 3; day++)
              ClassSlot(
                id: day,
                subjectId: 1,
                weekday: day,
                startMinutes: 9 * 60,
                endMinutes: 10 * 60,
                startDate: DateTime(2026, 7, 13),
              ),
          ],
          extras: <ExtraClass>[
            for (int i = 1; i <= 2; i++)
              ExtraClass(
                id: i,
                subjectId: 1,
                date: DateTime(2026, 8, i),
                startMinutes: 14 * 60,
                endMinutes: 15 * 60,
              ),
          ],
          holidays: const <Holiday>[],
          records: const <AttendanceRecord>[],
        ),
      ),
      settingsProvider.overrideWith(_StaticSettings.new),
      subjectActionsProvider.overrideWith(
        (Ref ref) => _HeldDelete(ref.read(actionCoreProvider), gate),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      navigatorObservers: <NavigatorObserver>[if (observer != null) observer],
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext context, WidgetRef ref, _) {
            ref.watch(timetableProvider);
            return TextButton(
              onPressed: () => showSubjectDetail(
                context,
                SubjectStats(
                  subject: subject,
                  present: 3,
                  absent: 1,
                  cancelled: 0,
                  target: 0.75,
                  plannedFromSlots: 10,
                ),
              ),
              child: const Text('open'),
            );
          },
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a subject being deleted does not open its editor',
      (WidgetTester tester) async {
    // Tall enough for the whole sheet; the default surface cuts off its
    // buttons.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final Completer<void> gate = Completer<void>();
    await tester.pumpWidget(_app(gate));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(find.text('Edit'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit subject'), findsNothing);

    gate.complete();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a double tap on Delete opens nothing from the sheet',
      (WidgetTester tester) async {
    _sized(tester, const Size(800, 2000));
    final Completer<void> gate = Completer<void>();
    final _PushCounter routes = _PushCounter();
    await tester.pumpWidget(_app(gate, observer: routes));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    final int before = routes.pushes;
    await _doubleTapOver(tester, find.text('Delete').last, 'Simulate');
    expect(routes.pushes, before);

    gate.complete();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a double tap on Cancel opens nothing from the sheet',
      (WidgetTester tester) async {
    // A name that wraps makes the dialog taller, which puts Cancel over
    // Simulate at this size.
    const Subject longName = Subject(
      id: 1,
      name: 'Applied Engineering Thermodynamics',
      colorValue: AppColors.defaultSubjectColor,
    );
    _sized(tester, const Size(800, 2100));
    final _PushCounter routes = _PushCounter();
    await tester.pumpWidget(
      _app(Completer<void>(), subject: longName, observer: routes),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    final int before = routes.pushes;
    await _doubleTapOver(tester, find.text('Cancel'), 'Simulate');
    expect(routes.pushes, before);
    expect(find.text('Simulate'), findsOneWidget);
  });
}

void _sized(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

/// Fails early unless the sheet's [target] sits under [button], since a tap
/// landing on blank sheet would pass for nothing.
Future<void> _doubleTapOver(
  WidgetTester tester,
  Finder button,
  String target,
) async {
  final Offset at = tester.getCenter(button);
  final Rect under = tester.getRect(
    find.ancestor(of: find.text(target), matching: find.byType(OutlinedButton)),
  );
  expect(under.contains(at), isTrue, reason: '$target is not under the button');
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tapAt(at);
  await tester.pumpAndSettle();
}
