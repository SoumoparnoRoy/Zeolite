import 'dart:async';

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
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/stats/stats_view.dart';
import 'package:zeolite/features/subjects/subjects_screen.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/widgets/common.dart';

/// Serves fixed settings so the screen never reaches SharedPreferences.
class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

/// Physics: a code, a category, 2 weekly classes, 1 one-off and 4 marks
/// (3 present of 4 held = 75%). Maths: bare, nothing recorded.
TimetableData _fixture() {
  final DateTime day = Dates.today();
  return TimetableData(
    categories: const <ClassCategory>[
      ClassCategory(id: 1, name: 'Lab', defaultDurationMinutes: 120),
    ],
    subjects: const <Subject>[
      Subject(
        id: 2,
        name: 'Mathematics',
        colorValue: AppColors.defaultSubjectColor,
      ),
      Subject(
        id: 1,
        name: 'Physics',
        code: 'PH101',
        categoryId: 1,
        colorValue: AppColors.defaultSubjectColor,
      ),
    ],
    slots: <ClassSlot>[
      ClassSlot(
        id: 1,
        subjectId: 1,
        weekday: DateTime.monday,
        startMinutes: 9 * 60,
        endMinutes: 11 * 60,
        startDate: day,
      ),
      ClassSlot(
        id: 2,
        subjectId: 1,
        weekday: DateTime.wednesday,
        startMinutes: 9 * 60,
        endMinutes: 11 * 60,
        startDate: day,
      ),
    ],
    extras: <ExtraClass>[
      ExtraClass(
        id: 1,
        subjectId: 1,
        date: day,
        startMinutes: 14 * 60,
        endMinutes: 15 * 60,
      ),
    ],
    holidays: const <Holiday>[],
    records: <AttendanceRecord>[
      for (int i = 0; i < 3; i++)
        AttendanceRecord(
          subjectId: 1,
          date: Dates.addDays(day, -i),
          startMinutes: 9 * 60,
          status: AttendanceStatus.present,
        ),
      AttendanceRecord(
        subjectId: 1,
        date: Dates.addDays(day, -3),
        startMinutes: 9 * 60,
        status: AttendanceStatus.absent,
      ),
    ],
  );
}

/// Holds a delete open until the test lets it finish, the way a slow write
/// does on a device.
class _HeldDelete extends SubjectActions {
  _HeldDelete(super.core, this.gate);

  final Completer<void> gate;

  @override
  Future<void> deleteSubject(int id) => gate.future;
}

/// [_fixture] plus enough subjects after Physics that rows sit under the
/// delete dialog's buttons.
TimetableData _crowded() {
  final TimetableData base = _fixture();
  return TimetableData(
    categories: base.categories,
    subjects: <Subject>[
      ...base.subjects,
      for (int id = 3; id < 15; id++)
        Subject(
          id: id,
          name: 'Topic $id',
          colorValue: AppColors.defaultSubjectColor,
        ),
    ],
    slots: base.slots,
    extras: base.extras,
    holidays: base.holidays,
    records: base.records,
  );
}

/// Phone width: on the default surface the list is capped narrower than the
/// dialog, so its buttons sit beside the rows rather than over them.
void _phoneSized(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

Future<void> _openDeleteDialog(WidgetTester tester, String name) async {
  final Finder card =
      find.ancestor(of: find.text(name), matching: find.byType(SurfaceCard));
  await tester.tap(
    find.descendant(of: card, matching: find.byIcon(Icons.more_vert_rounded)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete'));
  await tester.pumpAndSettle();
}

/// Two taps on [button]'s spot, the second while the dialog fades out, after
/// checking another subject's row really is underneath. The row being
/// deleted doesn't count: its own guard would pass the test without the
/// dialog's.
Future<void> _doubleTapOverARow(
  WidgetTester tester,
  Finder button, {
  required String deleting,
}) async {
  final Offset at = tester.getCenter(button);
  final Finder own = find.ancestor(
      of: find.text(deleting), matching: find.byType(SurfaceCard));
  final Set<Element> skip = own.evaluate().toSet();
  final bool overARow = find
      .byType(SurfaceCard)
      .evaluate()
      .where((Element e) => !skip.contains(e))
      .map((Element e) => e.renderObject! as RenderBox)
      .any((RenderBox box) =>
          (box.localToGlobal(Offset.zero) & box.size).contains(at));
  expect(overARow, isTrue, reason: 'no other row under the dialog button');
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tapAt(at);
  await tester.pumpAndSettle();
}

Widget _app(TimetableData data, {SubjectActions Function(Ref)? subjects}) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => data),
      settingsProvider.overrideWith(_StaticSettings.new),
      if (subjects != null) subjectActionsProvider.overrideWith(subjects),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: const SubjectsScreen(),
    ),
  );
}

void main() {
  testWidgets('leads each subject with its code, and totals in the header',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    expect(find.text('Subjects'), findsOneWidget);
    expect(find.text('Physics'), findsOneWidget);
    expect(find.text('Mathematics'), findsOneWidget);

    // The code leads, in mono, so a theory course and its lab stop reading as
    // duplicates of each other. Per-subject counts moved to the header.
    expect(find.text('PH101 · Lab'), findsOneWidget);
    // Two weekly slots; the one-off is not a weekly class.
    expect(find.text('2 subjects · 2 weekly classes'), findsOneWidget);
    // Nothing scheduled is the one count still worth saying inline.
    expect(find.text('no classes'), findsOneWidget);

    expect(find.text('75.00%'), findsOneWidget); // 3 present of 4 held
    expect(find.text('—'), findsOneWidget); // Mathematics, nothing marked
    expect(find.text('Add subject'), findsOneWidget);
  });

  testWidgets('shows the empty state when there are no subjects',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const TimetableData(
          categories: <ClassCategory>[],
          subjects: <Subject>[],
          slots: <ClassSlot>[],
          extras: <ExtraClass>[],
          holidays: <Holiday>[],
          records: <AttendanceRecord>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No subjects yet'), findsOneWidget);
    expect(find.text('Add your first subject'), findsOneWidget);
    // The FAB would duplicate the empty state's own call to action.
    expect(find.text('Add subject'), findsNothing);
  });

  testWidgets('a read that fails says so instead of offering a first subject',
      (WidgetTester tester) async {
    int reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timetableProvider.overrideWith((Ref ref) async {
            reads++;
            if (reads == 1) throw StateError('database is locked');
            return _fixture();
          }),
          settingsProvider.overrideWith(_StaticSettings.new),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const SubjectsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load your data'), findsOneWidget);
    expect(find.text('No subjects yet'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Physics'), findsOneWidget);
  });

  testWidgets('the delete dialog spells out exactly what is lost',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    // Physics sorts after Mathematics, so its menu is the second one.
    await tester.tap(find.byIcon(Icons.more_vert_rounded).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Physics?'), findsOneWidget);
    expect(
      find.textContaining(
        'Physics has 2 weekly classes, 1 one-off class and 4 attendance marks.',
      ),
      findsOneWidget,
    );

    // Cancelling must not touch the data layer.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Physics'), findsOneWidget);
  });

  testWidgets('a carried balance counts among what a delete loses',
      (WidgetTester tester) async {
    final TimetableData data = _fixture();
    await tester.pumpWidget(
      _app(
        TimetableData(
          categories: data.categories,
          subjects: <Subject>[
            const Subject(
              id: 2,
              name: 'Mathematics',
              colorValue: AppColors.defaultSubjectColor,
              priorHeld: 16,
              priorAttended: 14,
            ),
          ],
          slots: const <ClassSlot>[],
          extras: const <ExtraClass>[],
          holidays: const <Holiday>[],
          records: const <AttendanceRecord>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Nothing is a record, but 16 classes are still on the subject.
    expect(
      find.textContaining('Mathematics has 14 of 16 carried in.'),
      findsOneWidget,
    );
    expect(find.textContaining('nothing else is lost'), findsNothing);
  });

  testWidgets('a subject being deleted does not open its editor',
      (WidgetTester tester) async {
    final Completer<void> gate = Completer<void>();
    await tester.pumpWidget(
      _app(
        _fixture(),
        subjects: (Ref ref) => _HeldDelete(ref.read(actionCoreProvider), gate),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(find.text('Physics'), findsOneWidget);
    await tester.tap(find.text('Physics'));
    await tester.pumpAndSettle();
    expect(find.text('Edit subject'), findsNothing);

    gate.complete();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a double tap on Delete opens no other subject',
      (WidgetTester tester) async {
    _phoneSized(tester);
    final Completer<void> gate = Completer<void>();
    await tester.pumpWidget(
      _app(
        _crowded(),
        subjects: (Ref ref) => _HeldDelete(ref.read(actionCoreProvider), gate),
      ),
    );
    await tester.pumpAndSettle();

    await _openDeleteDialog(tester, 'Physics');
    await _doubleTapOverARow(tester, find.text('Delete').last,
        deleting: 'Physics');
    expect(find.text('Edit subject'), findsNothing);

    gate.complete();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a double tap on Cancel opens no subject',
      (WidgetTester tester) async {
    _phoneSized(tester);
    await tester.pumpWidget(_app(_crowded()));
    await tester.pumpAndSettle();

    await _openDeleteDialog(tester, 'Physics');
    await _doubleTapOverARow(tester, find.text('Cancel'), deleting: 'Physics');
    expect(find.text('Edit subject'), findsNothing);
    expect(find.text('Physics'), findsOneWidget);
  });

  testWidgets('rows take taps again however the dialog closes',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_crowded()));
    await tester.pumpAndSettle();

    Future<void> rowOpensItsEditor() async {
      await tester.tap(find.text('Mathematics'));
      await tester.pumpAndSettle();
      expect(find.text('Edit subject'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Edit subject'), findsNothing);
    }

    await _openDeleteDialog(tester, 'Physics');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await rowOpensItsEditor();

    await _openDeleteDialog(tester, 'Physics');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await rowOpensItsEditor();

    await _openDeleteDialog(tester, 'Physics');
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await rowOpensItsEditor();
  });

  testWidgets('the page behind takes taps when the screen closes mid-fade',
      (WidgetTester tester) async {
    int homeTaps = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timetableProvider.overrideWith((Ref ref) async => _crowded()),
          settingsProvider.overrideWith(_StaticSettings.new),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: SizedBox.expand(
                child: TextButton(
                  onPressed: () {
                    homeTaps++;
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SubjectsScreen(),
                      ),
                    );
                  },
                  child: const Text('home'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();

    await _openDeleteDialog(tester, 'Physics');
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 20));
    // A second back while the dialog fades takes the whole screen with it.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SubjectsScreen), findsNothing);

    await tester.tap(find.text('home'));
    expect(homeTaps, 2);
    await tester.pumpAndSettle();
  });

  testWidgets('a subject with no classes is sent to the Counts page',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timetableProvider.overrideWith(
            (Ref ref) async => const TimetableData(
              categories: <ClassCategory>[],
              subjects: <Subject>[
                Subject(
                  id: 2,
                  name: 'Mathematics',
                  colorValue: AppColors.defaultSubjectColor,
                  priorHeld: 4,
                  priorAttended: 3,
                ),
              ],
              slots: <ClassSlot>[],
              extras: <ExtraClass>[],
              holidays: <Holiday>[],
              records: <AttendanceRecord>[],
            ),
          ),
          settingsProvider.overrideWith(_StaticSettings.new),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Text('Tabs'),
        ),
      ),
    );
    unawaited(navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const SubjectsScreen()),
    ));
    await tester.pumpAndSettle();
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(SubjectsScreen)));

    expect(find.text('3 of 4 attended'), findsOneWidget);
    expect(find.text('75.00%'), findsOneWidget);

    await tester.tap(find.text('Count on the Stats page'));
    await tester.pumpAndSettle();

    expect(find.text('Tabs'), findsOneWidget);
    expect(container.read(statsViewProvider), StatsView.counts);
    expect(container.read(selectedTabProvider), shellTabs.indexOf('stats'));
  });
}
