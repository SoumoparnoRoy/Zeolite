import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/room.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/subjects/class_editor_sheets.dart';
import 'package:zeolite/state/providers.dart';

/// A global default of one hour and a Lab category of two, so the two rules
/// produce visibly different answers and a test cannot pass by accident.
class _StaticSettings extends SettingsController {
  _StaticSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

const AppSettings _plainSettings = AppSettings(
  onboarded: true,
  defaultClassDurationMinutes: 60,
);

/// The same day divided into 50-minute blocks, which makes a Lab two blocks.
const AppSettings _blockSettings = AppSettings(
  onboarded: true,
  defaultClassDurationMinutes: 50,
  dayStartMinutes: 9 * 60,
  dayEndMinutes: 17 * 60,
  blockMinutes: 50,
);

/// Captures what a form saved instead of writing it, so a test can tell a
/// weekly rule from a one-off rather than inferring it from the sheet.
/// The lists are owned by the test rather than by the fake, so a form that refuses
/// to save — and so never reads [actionsProvider] at all — can still be checked
/// for having written nothing.
class _RecordingActions extends TimetableActions {
  _RecordingActions(super.ref, {required this.slots, required this.extras});

  final List<ClassSlot> slots;
  final List<ExtraClass> extras;

  @override
  Future<void> addSlot(ClassSlot slot) async => slots.add(slot);

  @override
  Future<void> addExtraClass(ExtraClass extra) async => extras.add(extra);
}

/// Captures a saved subject rather than writing it, so the balance the form
/// built can be read back.
class _SubjectRecorder extends TimetableActions {
  _SubjectRecorder(super.ref, {required this.saved});

  final List<Subject> saved;

  @override
  Future<void> updateSubject(Subject subject) async => saved.add(subject);

  @override
  Future<int> addSubject(Subject subject) async {
    saved.add(subject);
    return 1;
  }

  /// The category sheet writes the category before it moves any subject, and
  /// this test double is only interested in the subjects.
  @override
  Future<void> updateCategory(ClassCategory category) async {}
}

TimetableData _fixture({
  List<ClassSlot> slots = const <ClassSlot>[],
  List<AttendanceRecord> records = const <AttendanceRecord>[],
}) =>
    TimetableData(
      categories: const <ClassCategory>[
        ClassCategory(id: 1, name: 'Lab', defaultDurationMinutes: 120),
      ],
      rooms: const <Room>[Room(id: 1, name: 'LT-3')],
      subjects: const <Subject>[
        Subject(
          id: 1,
          name: 'Physics',
          categoryId: 1,
          colorValue: AppColors.defaultSubjectColor,
        ),
        Subject(
          id: 2,
          name: 'Maths',
          colorValue: AppColors.defaultSubjectColor,
        ),
      ],
      slots: slots,
      extras: <ExtraClass>[],
      holidays: const <Holiday>[],
      records: records,
    );

Widget _host(
  Future<void> Function(BuildContext, WidgetRef) open, {
  AppSettings settings = _plainSettings,
  List<ClassSlot> slots = const <ClassSlot>[],
  List<AttendanceRecord> records = const <AttendanceRecord>[],
  TimetableActions Function(Ref)? actions,
}) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith(
        (Ref ref) async => _fixture(slots: slots, records: records),
      ),
      settingsProvider.overrideWith(() => _StaticSettings(settings)),
      if (actions != null) actionsProvider.overrideWith(actions),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext c, WidgetRef ref, _) {
            // Loaded before a sheet reads it, the way a real screen has it.
            ref.watch(timetableProvider);
            return TextButton(
              onPressed: () => open(c, ref),
              child: const Text('open'),
            );
          },
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Taps a button at the foot of a sheet, which is below the test viewport.
Future<void> _tapButton(WidgetTester tester, String label) async {
  final Finder button = find.text(label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// Drives the real time picker, which opens on the keyboard.
///
/// The point here is the form's reaction to a chosen time rather than the
/// picker itself. Scoped to the dialog because the sheet underneath has text
/// fields of its own.
Future<void> _pickTime(
  WidgetTester tester,
  Finder field,
  int hour,
  int minute,
) async {
  await tester.tap(field);
  await tester.pumpAndSettle();

  final Finder inputs = find.descendant(
    of: find.byType(Dialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(inputs.at(0), '${hour > 12 ? hour - 12 : hour}');
  await tester.enterText(inputs.at(1), minute.toString().padLeft(2, '0'));
  await tester.tap(find.text(hour >= 12 ? 'PM' : 'AM'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  group('a start time takes its length from the category', () {
    testWidgets('weekly form, subject chosen first', (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showSlotEditor(c, ref)));
      await _openSheet(tester);

      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      // Adopting the category on selection is what makes the order irrelevant.
      expect(find.text('11:00 am'), findsOneWidget);

      await _pickTime(tester, find.text('9:00 am'), 10, 0);
      expect(find.text('10:00 am'), findsOneWidget);
      expect(find.text('12:00 pm'), findsOneWidget);
    });

    testWidgets('weekly form, start time chosen first',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showSlotEditor(c, ref)));
      await _openSheet(tester);

      // No subject yet, so the global hour applies.
      await _pickTime(tester, find.text('9:00 am'), 10, 0);
      expect(find.text('11:00 am'), findsOneWidget);

      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      expect(find.text('12:00 pm'), findsOneWidget);
    });

    testWidgets('one-off form, either order', (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showExtraClassEditor(c, ref)));
      await _openSheet(tester);

      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      expect(find.text('11:00 am'), findsOneWidget);

      await _pickTime(tester, find.text('9:00 am'), 11, 0);
      expect(find.text('11:00 am'), findsOneWidget);
      expect(find.text('1:00 pm'), findsOneWidget);
    });

    testWidgets('a subject with no category falls back to the global length',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showSlotEditor(c, ref)));
      await _openSheet(tester);

      await tester.tap(find.text('Maths'));
      await tester.pumpAndSettle();
      // Named explicitly, so "the category is not applying" and "this subject
      // has no category" cannot look the same on screen.
      expect(find.text('no category · 1h'), findsOneWidget);
      expect(find.text('10:00 am'), findsOneWidget);
    });

    testWidgets('an end time set by hand pins the length',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showSlotEditor(c, ref)));
      await _openSheet(tester);

      await _pickTime(tester, find.text('10:00 am'), 9, 30);
      // Picking the subject must not stretch a span the user chose.
      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      expect(find.text('9:30 am'), findsOneWidget);
    });

    testWidgets('editing an existing class keeps its own length until moved',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSlotEditor(
            c,
            ref,
            slot: ClassSlot(
              id: 9,
              subjectId: 1,
              weekday: DateTime.monday,
              startMinutes: 9 * 60,
              endMinutes: 10 * 60,
              startDate: Dates.today(),
            ),
          ),
        ),
      );
      await _openSheet(tester);
      expect(find.text('10:00 am'), findsOneWidget);

      await _pickTime(tester, find.text('9:00 am'), 11, 0);
      expect(find.text('1:00 pm'), findsOneWidget);
    });
  });

  group('the length rule is named on screen', () {
    testWidgets('the category and its length are both shown',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showSlotEditor(c, ref)));
      await _openSheet(tester);
      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();

      expect(find.text('Lab · 2h'), findsOneWidget);
    });

    testWidgets('with a block length set, the count is shown too',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host((c, ref) => showSlotEditor(c, ref), settings: _blockSettings),
      );
      await _openSheet(tester);
      await tester.tap(find.text('Maths'));
      await tester.pumpAndSettle();

      // 50 minutes is exactly one block, so it reads as one.
      expect(find.text('no category · 1 block · 50m'), findsOneWidget);
    });
  });

  group('rooms saved in Settings', () {
    testWidgets('are offered as chips and fill the field in',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showExtraClassEditor(c, ref)));
      await _openSheet(tester);

      // The chip sits below the field, so once the field holds the same text
      // the last match is the chip.
      await tester.tap(find.text('LT-3').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'LT-3'))
            .controller
            ?.text,
        'LT-3',
      );

      // Tapping the chosen room again clears it, matching the attendance
      // buttons rather than inventing a second rule.
      await tester.tap(find.text('LT-3').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'LT-3'), findsNothing);
    });
  });

  group('filling a block on the grid', () {
    testWidgets('offers block counts and defaults to the category',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showBlockClassEditor(
            c,
            ref,
            date: Dates.startOfWeek(Dates.today()),
            blockIndex: 0,
          ),
          settings: _blockSettings,
        ),
      );
      await _openSheet(tester);

      expect(find.text('Monday · block 1'), findsOneWidget);
      // Nothing chosen yet: the block's own times.
      expect(find.text('9:00 am – 9:50 am'), findsOneWidget);

      // A 2h Lab on 50-minute blocks rounds to 2 blocks, so 9:00–10:40.
      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      expect(find.text('9:00 am – 10:40 am'), findsOneWidget);

      await tester.tap(find.text('3 blocks'));
      await tester.pumpAndSettle();
      expect(find.text('9:00 am – 11:30 am'), findsOneWidget);
    });

    testWidgets('repeats weekly by default, and writes a rule',
        (WidgetTester tester) async {
      final List<ClassSlot> written = <ClassSlot>[];
      final List<ExtraClass> extras = <ExtraClass>[];
      await tester.pumpWidget(
        _host(
          (c, ref) => showBlockClassEditor(
            c,
            ref,
            date: Dates.startOfWeek(Dates.today()),
            blockIndex: 0,
          ),
          settings: _blockSettings,
          actions: (Ref ref) =>
              _RecordingActions(ref, slots: written, extras: extras),
        ),
      );
      await _openSheet(tester);

      expect(find.text('First class'), findsOneWidget);
      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      await _tapButton(tester, 'Add to timetable');

      expect(extras, isEmpty);
      expect(written, hasLength(1));
      expect(written.single.weekday, DateTime.monday);
      expect(written.single.startMinutes, 9 * 60);
    });

    testWidgets('a one-off is locked to the tapped cell and writes an extra',
        (WidgetTester tester) async {
      final DateTime monday = Dates.startOfWeek(Dates.today());
      final List<ClassSlot> written = <ClassSlot>[];
      final List<ExtraClass> extras = <ExtraClass>[];
      await tester.pumpWidget(
        _host(
          (c, ref) =>
              showBlockClassEditor(c, ref, date: monday, blockIndex: 0),
          settings: _blockSettings,
          actions: (Ref ref) =>
              _RecordingActions(ref, slots: written, extras: extras),
        ),
      );
      await _openSheet(tester);

      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Just this once'));
      await tester.pumpAndSettle();

      // The cell fixes the date, so no picker can contradict the grid.
      expect(find.text('First class'), findsNothing);
      expect(find.textContaining('only.'), findsOneWidget);

      await _tapButton(tester, 'Add one-off class');

      expect(written, isEmpty);
      expect(extras, hasLength(1));
      final ExtraClass saved = extras.single;
      expect(Dates.keyOf(saved.date), Dates.keyOf(monday));
      // The block count still comes from the Lab category: 2 × 50 minutes.
      expect(saved.startMinutes, 9 * 60);
      expect(saved.endMinutes, 10 * 60 + 40);
    });

    testWidgets('a one-off on top of a weekly class of the same subject is '
        'refused', (WidgetTester tester) async {
      final DateTime monday = Dates.startOfWeek(Dates.today());
      final List<ClassSlot> written = <ClassSlot>[];
      final List<ExtraClass> extras = <ExtraClass>[];
      await tester.pumpWidget(
        _host(
          (c, ref) =>
              showBlockClassEditor(c, ref, date: monday, blockIndex: 0),
          settings: _blockSettings,
          slots: <ClassSlot>[
            ClassSlot(
              id: 1,
              subjectId: 1,
              weekday: DateTime.monday,
              startMinutes: 9 * 60,
              endMinutes: 10 * 60 + 40,
              startDate: monday,
            ),
          ],
          actions: (Ref ref) =>
              _RecordingActions(ref, slots: written, extras: extras),
        ),
      );
      await _openSheet(tester);

      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Just this once'));
      await tester.pumpAndSettle();
      await _tapButton(tester, 'Add one-off class');

      // Both would key to (Physics, this Monday, 9:00) and share one mark.
      expect(find.textContaining('share one'), findsOneWidget);
      expect(extras, isEmpty);
    });
  });

  group('removing a class that has attendance against it', () {
    final DateTime monday = Dates.startOfWeek(Dates.today());
    final ClassSlot weekly = ClassSlot(
      id: 7,
      subjectId: 1,
      weekday: DateTime.monday,
      startMinutes: 9 * 60,
      endMinutes: 10 * 60,
      startDate: Dates.addDays(monday, -70),
    );

    ClassSession sessionOn(DateTime date) => ClassSession(
          subject: const Subject(
            id: 1,
            name: 'Physics',
            categoryId: 1,
            colorValue: AppColors.defaultSubjectColor,
          ),
          date: date,
          startMinutes: 9 * 60,
          endMinutes: 10 * 60,
          slotId: 7,
        );

    AttendanceRecord markOn(DateTime date, {int startMinutes = 9 * 60}) =>
        AttendanceRecord(
          subjectId: 1,
          date: date,
          startMinutes: startMinutes,
          status: AttendanceStatus.present,
        );

    testWidgets('the destructive pair is offered', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
          records: <AttendanceRecord>[markOn(Dates.addDays(monday, -7))],
        ),
      );
      await _openSheet(tester);

      expect(find.text('Delete this weekly class'), findsOneWidget);
      expect(find.text('Delete it and its attendance'), findsOneWidget);
      // A warning without the number is just a shrug.
      expect(find.textContaining('1 mark'), findsOneWidget);
    });

    testWidgets('with nothing recorded there is only one delete',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
        ),
      );
      await _openSheet(tester);

      expect(find.text('Delete this weekly class'), findsOneWidget);
      expect(find.text('Delete it and its attendance'), findsNothing);
    });

    testWidgets('a mark at another time belongs to another class',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
          records: <AttendanceRecord>[
            markOn(Dates.addDays(monday, -7), startMinutes: 14 * 60),
            markOn(Dates.addDays(monday, -6)),
          ],
        ),
      );
      await _openSheet(tester);

      expect(find.text('Delete it and its attendance'), findsNothing);
    });
  });

  group('the subject balance', () {
    Future<List<Subject>> save(
      WidgetTester tester, {
      required String held,
      required String attended,
      String? total,
    }) async {
      final List<Subject> saved = <Subject>[];
      await tester.pumpWidget(
        _host(
          (c, ref) => showSubjectEditor(c, ref, subject: _fixture().subjects[1]),
          actions: (Ref ref) => _SubjectRecorder(ref, saved: saved),
        ),
      );
      await _openSheet(tester);

      final Finder toggle = find.text('Already attended');
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Held'), held);
      await tester.enterText(
        find.widgetWithText(TextField, 'Attended'),
        attended,
      );
      if (total != null) {
        await tester.enterText(
          find.widgetWithText(TextField, 'Classes all term'),
          total,
        );
      }
      await _tapButton(tester, 'Save');
      return saved;
    }

    testWidgets('carries the three numbers onto the subject',
        (WidgetTester tester) async {
      final List<Subject> saved =
          await save(tester, held: '16', attended: '14', total: '18');

      expect(saved, hasLength(1));
      expect(saved.single.priorHeld, 16);
      expect(saved.single.priorAttended, 14);
      expect(saved.single.expectedTotal, 18);
    });

    testWidgets('refuses to attend more classes than were held',
        (WidgetTester tester) async {
      final List<Subject> saved =
          await save(tester, held: '5', attended: '9');

      expect(find.text('Attended cannot be more than held.'), findsOneWidget);
      expect(saved, isEmpty);
    });

    testWidgets('refuses a term total smaller than what is already held',
        (WidgetTester tester) async {
      final List<Subject> saved =
          await save(tester, held: '16', attended: '14', total: '9');

      expect(
        find.text('The term total is less than what is held.'),
        findsOneWidget,
      );
      expect(saved, isEmpty);
    });
  });

  testWidgets('a category files subjects in and out of itself',
      (WidgetTester tester) async {
    final List<Subject> saved = <Subject>[];
    await tester.pumpWidget(_host(
      (BuildContext c, WidgetRef ref) => showCategoryEditor(
        c,
        ref,
        category: const ClassCategory(
          id: 1,
          name: 'Lab',
          defaultDurationMinutes: 120,
        ),
      ),
      actions: (Ref ref) => _SubjectRecorder(ref, saved: saved),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Physics is in this category and Maths is in none, so one tap each is a
    // move in and a move out.
    for (final String name in <String>['Maths', 'Physics']) {
      await tester.ensureVisible(find.text(name));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    final Finder save = find.widgetWithText(FilledButton, 'Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(saved, hasLength(2));
    expect(
      saved.firstWhere((Subject s) => s.name == 'Maths').categoryId,
      1,
    );
    expect(
      saved.firstWhere((Subject s) => s.name == 'Physics').categoryId,
      isNull,
    );
  });
}
