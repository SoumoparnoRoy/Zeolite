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
import 'package:zeolite/data/models/slot_override.dart';
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
/// Tells the two edit paths apart: a plain save and one that carries the
/// marks across.
class _EditRecorder extends TimetableActions {
  _EditRecorder(super.ref);

  final List<ClassSlot> plain = <ClassSlot>[];
  final List<ClassSlot> moved = <ClassSlot>[];

  @override
  Future<void> updateSlot(ClassSlot slot) async => plain.add(slot);

  @override
  Future<void> updateSlotAndMoveMarks(
    ClassSlot previous,
    ClassSlot updated,
  ) async =>
      moved.add(updated);
}

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
  List<SlotOverride> overrides = const <SlotOverride>[],
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
      overrides: overrides,
    );

Widget _host(
  Future<void> Function(BuildContext, WidgetRef) open, {
  AppSettings settings = _plainSettings,
  List<ClassSlot> slots = const <ClassSlot>[],
  List<AttendanceRecord> records = const <AttendanceRecord>[],
  List<SlotOverride> slotOverrides = const <SlotOverride>[],
  TimetableActions Function(Ref)? actions,
}) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith(
        (Ref ref) async => _fixture(
          slots: slots,
          records: records,
          overrides: slotOverrides,
        ),
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
    testWidgets('weekly form, subject chosen first',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showSlotEditor(c, ref)));
      await _openSheet(tester);

      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      // Adopting the category on selection is what makes the order irrelevant.
      expect(find.text('11:00 AM'), findsOneWidget);

      await _pickTime(tester, find.text('9:00 AM'), 10, 0);
      expect(find.text('10:00 AM'), findsOneWidget);
      expect(find.text('12:00 PM'), findsOneWidget);
    });

    testWidgets('weekly form, start time chosen first',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showSlotEditor(c, ref)));
      await _openSheet(tester);

      // No subject yet, so the global hour applies.
      await _pickTime(tester, find.text('9:00 AM'), 10, 0);
      expect(find.text('11:00 AM'), findsOneWidget);

      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      expect(find.text('12:00 PM'), findsOneWidget);
    });

    testWidgets('one-off form, either order', (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showExtraClassEditor(c, ref)));
      await _openSheet(tester);

      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      expect(find.text('11:00 AM'), findsOneWidget);

      await _pickTime(tester, find.text('9:00 AM'), 11, 0);
      expect(find.text('11:00 AM'), findsOneWidget);
      expect(find.text('1:00 PM'), findsOneWidget);
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
      expect(find.text('10:00 AM'), findsOneWidget);
    });

    testWidgets('an end time set by hand pins the length',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host((c, ref) => showSlotEditor(c, ref)));
      await _openSheet(tester);

      await _pickTime(tester, find.text('10:00 AM'), 9, 30);
      // Picking the subject must not stretch a span the user chose.
      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      expect(find.text('9:30 AM'), findsOneWidget);
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
      expect(find.text('10:00 AM'), findsOneWidget);

      await _pickTime(tester, find.text('9:00 AM'), 11, 0);
      expect(find.text('1:00 PM'), findsOneWidget);
    });
  });

  group('an edit that would strand marks', () {
    final ClassSlot existing = ClassSlot(
      id: 9,
      subjectId: 1,
      weekday: Dates.today().weekday,
      startMinutes: 9 * 60,
      endMinutes: 10 * 60,
      startDate: Dates.addDays(Dates.today(), -7),
    );
    final AttendanceRecord marked = AttendanceRecord(
      subjectId: 1,
      date: Dates.today(),
      startMinutes: 9 * 60,
      status: AttendanceStatus.present,
    );

    Future<_EditRecorder> edit(
      WidgetTester tester, {
      required List<AttendanceRecord> records,
      String? pickSubject,
    }) async {
      late _EditRecorder recorder;
      await tester.pumpWidget(
        _host(
          (c, ref) => showSlotEditor(c, ref, slot: existing),
          records: records,
          slots: <ClassSlot>[existing],
          actions: (Ref ref) => recorder = _EditRecorder(ref),
        ),
      );
      await _openSheet(tester);
      if (pickSubject != null) {
        await tester.tap(find.text(pickSubject));
        await tester.pumpAndSettle();
      }
      await _tapButton(tester, 'Save changes');
      return recorder;
    }

    testWidgets('re-pointing a marked class takes its marks with it',
        (WidgetTester tester) async {
      final _EditRecorder recorder = await edit(
        tester,
        records: <AttendanceRecord>[marked],
        pickSubject: 'Maths',
      );

      expect(find.text('Move the attendance too?'), findsNothing);
      expect(recorder.moved.single.subjectId, 2);
      expect(recorder.plain, isEmpty);
    });

    testWidgets('a class with no marks yet is a plain update',
        (WidgetTester tester) async {
      final _EditRecorder recorder = await edit(
        tester,
        records: const <AttendanceRecord>[],
        pickSubject: 'Maths',
      );

      expect(recorder.plain.single.subjectId, 2);
      expect(recorder.moved, isEmpty);
    });

    testWidgets('an edit that does not move the key leaves marks alone',
        (WidgetTester tester) async {
      final _EditRecorder recorder = await edit(
        tester,
        records: <AttendanceRecord>[marked],
      );

      expect(recorder.plain, hasLength(1));
      expect(recorder.moved, isEmpty);
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
      expect(find.text('9:00 AM – 9:50 AM'), findsOneWidget);

      // A 2h Lab on 50-minute blocks rounds to 2 blocks, so 9:00–10:40.
      await tester.tap(find.text('Physics'));
      await tester.pumpAndSettle();
      expect(find.text('9:00 AM – 10:40 AM'), findsOneWidget);

      await tester.tap(find.text('3 blocks'));
      await tester.pumpAndSettle();
      expect(find.text('9:00 AM – 11:30 AM'), findsOneWidget);
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
          (c, ref) => showBlockClassEditor(c, ref, date: monday, blockIndex: 0),
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

    testWidgets(
        'a one-off on top of a weekly class of the same subject is '
        'refused', (WidgetTester tester) async {
      final DateTime monday = Dates.startOfWeek(Dates.today());
      final List<ClassSlot> written = <ClassSlot>[];
      final List<ExtraClass> extras = <ExtraClass>[];
      await tester.pumpWidget(
        _host(
          (c, ref) => showBlockClassEditor(c, ref, date: monday, blockIndex: 0),
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

    testWidgets('one delete, and it names what the marks cost',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
          records: <AttendanceRecord>[markOn(Dates.addDays(monday, -7))],
        ),
      );
      await _openSheet(tester);

      expect(find.text('Delete this weekly class'), findsOneWidget);
      expect(find.text('Delete it and its attendance'), findsNothing);
      // A warning without the number is just a shrug.
      expect(find.textContaining('1 mark'), findsOneWidget);
    });

    testWidgets('with nothing recorded the marks are not mentioned',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
        ),
      );
      await _openSheet(tester);

      expect(find.text('Delete this weekly class'), findsOneWidget);
      expect(find.textContaining('mark'), findsNothing);
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

      expect(find.textContaining('mark'), findsNothing);
    });

    testWidgets('the edit tile goes where a tap already opens the editor',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday),
              tapOpensEditor: true),
          slots: <ClassSlot>[weekly],
        ),
      );
      await _openSheet(tester);

      expect(find.text('Edit the weekly class'), findsNothing);
      expect(find.text('Delete this weekly class'), findsOneWidget);
    });

    testWidgets('clearing the mark goes where the buttons already do it',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday),
              marksInline: true),
          slots: <ClassSlot>[weekly],
          records: <AttendanceRecord>[markOn(monday)],
        ),
      );
      await _openSheet(tester);

      expect(find.text('Clear the mark'), findsNothing);
      expect(find.text('Edit the weekly class'), findsOneWidget);
    });

    testWidgets('a weekly class offers both scopes, and no cancel tile',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
        ),
      );
      await _openSheet(tester);

      expect(find.text('Edit just this class'), findsOneWidget);
      expect(find.text('Edit the weekly class'), findsOneWidget);
      expect(find.text('Delete just this class'), findsOneWidget);
      // Cancelling is a status, and every date is reachable on Today.
      expect(find.text('Cancel just this class'), findsNothing);
    });

    testWidgets('the rule tile owns up to weeks that were set by hand',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
          slotOverrides: <SlotOverride>[
            SlotOverride(
              slotId: 7,
              date: Dates.addDays(monday, 7),
              room: 'R204',
            ),
          ],
        ),
      );
      await _openSheet(tester);

      expect(
        find.textContaining('Weeks you edited on their own keep what you set'),
        findsOneWidget,
      );
    });

    testWidgets('with no exceptions the rule tile promises every week plainly',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
        ),
      );
      await _openSheet(tester);

      expect(find.textContaining('Weeks you edited on their own'), findsNothing);
    });

    testWidgets('stopping it warns only about marks from the cut on',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
          records: <AttendanceRecord>[
            markOn(Dates.addDays(monday, -7)),
            markOn(monday),
          ],
        ),
      );
      await _openSheet(tester);
      await tester.tap(find.text('Stop repeating from this date'));
      await tester.pumpAndSettle();

      // The earlier Monday is not counted: its week survives the cut.
      expect(
        find.text('Stop repeating and remove its attendance?'),
        findsOneWidget,
      );
      expect(find.textContaining('1 mark'), findsWidgets);
    });

    testWidgets('stopping it says nothing when only earlier weeks are marked',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
          records: <AttendanceRecord>[markOn(Dates.addDays(monday, -7))],
        ),
      );
      await _openSheet(tester);

      expect(
        find.textContaining('Earlier weeks are kept, and so is everything'),
        findsOneWidget,
      );
    });

    testWidgets('cancelling the confirm deletes nothing at all',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          (c, ref) => showSessionOptions(c, ref, sessionOn(monday)),
          slots: <ClassSlot>[weekly],
          records: <AttendanceRecord>[markOn(Dates.addDays(monday, -7))],
        ),
      );
      await _openSheet(tester);
      await tester.tap(find.text('Delete this weekly class'));
      await tester.pumpAndSettle();

      expect(find.text('Delete the class and its attendance?'), findsOneWidget);
      await _tapButton(tester, 'Cancel');

      // The sheet is still open: cancel abandons the whole thing rather than
      // falling back to a delete that keeps the marks.
      expect(find.text('Delete this weekly class'), findsOneWidget);
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
          (c, ref) =>
              showSubjectEditor(c, ref, subject: _fixture().subjects[1]),
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
      final List<Subject> saved = await save(tester, held: '5', attended: '9');

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
