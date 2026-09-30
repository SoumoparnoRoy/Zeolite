import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/untimed_match.dart';
import 'package:zeolite/features/settings/untimed_match_screen.dart';
import 'package:zeolite/features/subjects/class_editor_sheets.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async =>
      AppSettings(onboarded: true, termStart: DateTime(2026, 7, 27));
}

class _MatchRecorder extends AttendanceActions {
  _MatchRecorder(super.core);

  final List<UntimedMatch> matched = <UntimedMatch>[];

  @override
  Future<int> matchUntimed(List<UntimedMatch> matches) async {
    matched.addAll(matches);
    return matches.length;
  }
}

class _QuietSchedule extends ScheduleActions {
  _QuietSchedule(super.core);

  @override
  Future<void> updateSlot(ClassSlot slot) async {}
}

final DateTime _monday = DateTime(2026, 8, 3);

ClassSlot _slot(int id, int subjectId) => ClassSlot(
      id: id,
      subjectId: subjectId,
      weekday: DateTime.monday,
      startMinutes: 540 + 60 * id,
      endMinutes: 590 + 60 * id,
      startDate: _monday,
    );

AttendanceRecord _untimed(int subjectId) => AttendanceRecord(
      subjectId: subjectId,
      date: _monday,
      startMinutes: AttendanceRecord.untimed(1),
      status: AttendanceStatus.present,
    );

Widget _host(
  Widget Function(WidgetRef) child,
  _MatchRecorder Function(Ref) actions,
) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith(
        (Ref ref) async => TimetableData(
          categories: const <ClassCategory>[],
          subjects: const <Subject>[
            Subject(id: 1, name: 'Course 1', colorValue: 0),
            Subject(id: 2, name: 'Course 2', colorValue: 0),
          ],
          slots: <ClassSlot>[_slot(1, 1), _slot(2, 2)],
          extras: const <ExtraClass>[],
          holidays: const <Holiday>[],
          records: <AttendanceRecord>[_untimed(1), _untimed(2)],
        ),
      ),
      settingsProvider.overrideWith(_StaticSettings.new),
      attendanceActionsProvider.overrideWith(actions),
      scheduleActionsProvider
          .overrideWith((Ref ref) => _QuietSchedule(ActionCore(ref))),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext c, WidgetRef ref, _) {
            ref.watch(timetableProvider);
            return child(ref);
          },
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('every subject starts ticked and only ticked ones are matched',
      (WidgetTester tester) async {
    late _MatchRecorder recorder;
    await tester.pumpWidget(_host(
      (_) => const UntimedMatchScreen(),
      (Ref ref) => recorder = _MatchRecorder(ActionCore(ref)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Match 2 classes'), findsOneWidget);
    await tester.tap(find.text('Course 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Match 1 class'));
    await tester.pumpAndSettle();

    expect(recorder.matched.single.record.subjectId, 1);
    expect(recorder.matched.single.moved.startMinutes, 600);
  });

  testWidgets('saving a class asks before matching its subject',
      (WidgetTester tester) async {
    late _MatchRecorder recorder;
    await tester.pumpWidget(_host(
      (WidgetRef ref) => Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () => showSlotEditor(c, ref, slot: _slot(2, 2)),
          child: const Text('open'),
        ),
      ),
      (Ref ref) => recorder = _MatchRecorder(ActionCore(ref)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final Finder save = find.text('Save changes');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Match 1 class with no time?'), findsOneWidget);
    await tester.tap(find.text('Match them'));
    await tester.pumpAndSettle();

    // Only the subject that was saved, not every one that could match.
    expect(recorder.matched.single.record.subjectId, 2);
  });

  testWidgets('a new class for a subject with untimed marks starts at term',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      (WidgetRef ref) => Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () => showSlotEditor(c, ref),
          child: const Text('open'),
        ),
      ),
      (Ref ref) => _MatchRecorder(ActionCore(ref)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Course 1'));
    await tester.pumpAndSettle();

    // Said in the folded summary, and on the field once it is opened.
    expect(find.textContaining('from 27 Jul 2026'), findsOneWidget);
    await tester.ensureVisible(find.text('More options'));
    await tester.tap(find.text('More options'));
    await tester.pumpAndSettle();
    final Finder first = find.text('27 Jul 2026');
    await tester.ensureVisible(first);
    expect(first, findsOneWidget);
  });
}
