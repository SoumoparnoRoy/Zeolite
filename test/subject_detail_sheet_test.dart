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

Widget _app(Completer<void> gate) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith(
        (Ref ref) async => const TimetableData(
          categories: <ClassCategory>[],
          subjects: <Subject>[_physics],
          slots: <ClassSlot>[],
          extras: <ExtraClass>[],
          holidays: <Holiday>[],
          records: <AttendanceRecord>[],
        ),
      ),
      settingsProvider.overrideWith(_StaticSettings.new),
      subjectActionsProvider.overrideWith(
        (Ref ref) => _HeldDelete(ref.read(actionCoreProvider), gate),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext context, WidgetRef ref, _) {
            ref.watch(timetableProvider);
            return TextButton(
              onPressed: () => showSubjectDetail(
                context,
                const SubjectStats(
                  subject: _physics,
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
}
