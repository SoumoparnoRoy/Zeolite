import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/subjects/attendance_log_screen.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/widgets/common.dart';

import 'fake_notifications.dart';

const Subject _physics = Subject(
  id: 1,
  name: 'Physics',
  colorValue: AppColors.defaultSubjectColor,
);

/// Records writes instead of touching sqflite, which is unavailable under
/// flutter_test. Only the two methods the log can reach are overridden.
class _FakeRepository extends ZeoliteRepository {
  final List<AttendanceRecord> written = <AttendanceRecord>[];
  final List<String> cleared = <String>[];

  @override
  Future<void> setAttendance(AttendanceRecord record) async {
    written.add(record);
  }

  @override
  Future<void> clearAttendance(
    int subjectId,
    DateTime date,
    int startMinutes,
  ) async {
    cleared.add(AttendanceRecord.keyFor(subjectId, date, startMinutes));
  }
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

/// A weekly class on today's weekday running for the last two weeks, so the
/// engine generates occurrences at today-14, today-7 and today.
///
/// Marks: present at today-7, plus a stray mark on a day with no class at all,
/// standing in for what deleting a weekly rule leaves behind.
TimetableData _fixture() {
  final DateTime today = Dates.today();
  return TimetableData(
    categories: const <ClassCategory>[],
    subjects: const <Subject>[_physics],
    slots: <ClassSlot>[
      ClassSlot(
        id: 1,
        subjectId: 1,
        weekday: today.weekday,
        startMinutes: 9 * 60,
        endMinutes: 10 * 60,
        startDate: Dates.addDays(today, -14),
      ),
    ],
    extras: const <ExtraClass>[],
    holidays: const <Holiday>[],
    records: <AttendanceRecord>[
      AttendanceRecord(
        subjectId: 1,
        date: Dates.addDays(today, -7),
        startMinutes: 9 * 60,
        status: AttendanceStatus.present,
      ),
      AttendanceRecord(
        subjectId: 1,
        date: Dates.addDays(today, -3),
        startMinutes: 15 * 60,
        status: AttendanceStatus.absent,
      ),
    ],
  );
}

Widget _app(
  TimetableData data, {
  _FakeRepository? repo,
  Subject subject = _physics,
}) {
  final DateTime today = Dates.today();
  return ProviderScope(
    overrides: [
      notificationsProvider.overrideWithValue(QuietNotifications()),
      timetableProvider.overrideWith((Ref ref) async => data),
      settingsProvider.overrideWith(
        () => _StaticSettings(
          AppSettings(
            onboarded: true,
            termStart: Dates.addDays(today, -14),
            termEnd: Dates.addDays(today, 60),
          ),
        ),
      ),
      if (repo != null) repositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: AttendanceLogScreen(subject: subject),
    ),
  );
}

void main() {
  setUpAll(() async {
    // The test font's square glyphs would make the phone-width check below
    // measure text that is far wider than the real thing.
    final FontLoader loader = FontLoader(AppFonts.sans);
    for (final String weight in <String>['Medium', 'SemiBold', 'ExtraBold']) {
      loader
          .addFont(rootBundle.load('assets/fonts/PlusJakartaSans-$weight.ttf'));
    }
    await loader.load();
  });

  testWidgets('lists every past class and every stray mark',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    final DateTime today = Dates.today();

    // 3 generated occurrences + 1 mark with no occurrence behind it.
    expect(find.textContaining('4 of 4 marked'), findsNothing);
    expect(find.textContaining('2 of 4 marked'), findsOneWidget);

    expect(find.text(Dates.formatFull(today)), findsOneWidget);
    expect(
        find.text(Dates.formatFull(Dates.addDays(today, -7))), findsOneWidget);
    expect(
        find.text(Dates.formatFull(Dates.addDays(today, -14))), findsOneWidget);
    // The stray mark's day has no scheduled class, but must still be reachable.
    expect(
        find.text(Dates.formatFull(Dates.addDays(today, -3))), findsOneWidget);
  });

  testWidgets('the bar carries the percentage for the subject',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    // One present and one absent inside the term.
    expect(find.text('50%', findRichText: true), findsOneWidget);
    expect(find.text('2 of 4 marked · 1 of 2 attended'), findsOneWidget);
  });

  testWidgets('a long name gives way to the percentage on a phone',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2424);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(
      _fixture(),
      subject: const Subject(
        id: 1,
        name: 'Subject 1 with a name far too long for one line',
        colorValue: AppColors.defaultSubjectColor,
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('50%', findRichText: true), findsOneWidget);
    // The name may shorten; the counts under it must not.
    final RenderParagraph counts = tester.renderObject(
      find.text('2 of 4 marked · 1 of 2 attended'),
    );
    expect(counts.didExceedMaxLines, isFalse);
  });

  testWidgets('explains a mark with no class sitting under it',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    // Worded for both ways one appears: a deleted rule, and a mark imported
    // against a timetable that was never built.
    expect(
      find.textContaining('No class on your timetable sits here'),
      findsOneWidget,
    );
  });

  testWidgets('shows the empty state when the subject has never met',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const TimetableData(
          categories: <ClassCategory>[],
          subjects: <Subject>[_physics],
          slots: <ClassSlot>[],
          extras: <ExtraClass>[],
          holidays: <Holiday>[],
          records: <AttendanceRecord>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing to show yet'), findsOneWidget);
  });

  testWidgets('marking an unmarked class writes it through',
      (WidgetTester tester) async {
    final _FakeRepository repo = _FakeRepository();
    await tester.pumpWidget(_app(_fixture(), repo: repo));
    await tester.pumpAndSettle();

    // The newest row is today's class, which has no mark yet.
    await tester.tap(find.byIcon(AttendanceStatus.present.icon).first);
    await tester.pumpAndSettle();

    expect(repo.written, hasLength(1));
    expect(repo.written.single.subjectId, 1);
    expect(repo.written.single.status, AttendanceStatus.present);
    expect(Dates.keyOf(repo.written.single.date), Dates.keyOf(Dates.today()));
    expect(repo.cleared, isEmpty);
  });

  testWidgets('a stray mark can be removed, but only after confirming',
      (WidgetTester tester) async {
    final _FakeRepository repo = _FakeRepository();
    await tester.pumpWidget(_app(_fixture(), repo: repo));
    await tester.pumpAndSettle();

    expect(find.text('Remove this mark'), findsOneWidget);

    // Backing out must not delete anything.
    await tester.tap(find.text('Remove this mark'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this mark?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(repo.cleared, isEmpty);

    await tester.tap(find.text('Remove this mark'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(
      repo.cleared.single,
      AttendanceRecord.keyFor(1, Dates.addDays(Dates.today(), -3), 15 * 60),
    );
    expect(repo.written, isEmpty);
  });

  testWidgets('a normal row offers no remove action',
      (WidgetTester tester) async {
    // Only stray marks get the destructive affordance; a scheduled class is
    // corrected with the status toggles.
    await tester.pumpWidget(
      _app(
        TimetableData(
          categories: const <ClassCategory>[],
          subjects: const <Subject>[_physics],
          slots: <ClassSlot>[
            ClassSlot(
              id: 1,
              subjectId: 1,
              weekday: Dates.today().weekday,
              startMinutes: 9 * 60,
              endMinutes: 10 * 60,
              startDate: Dates.addDays(Dates.today(), -14),
            ),
          ],
          extras: const <ExtraClass>[],
          holidays: const <Holiday>[],
          records: const <AttendanceRecord>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remove this mark'), findsNothing);
  });

  testWidgets('tapping the status a class already has clears it',
      (WidgetTester tester) async {
    final _FakeRepository repo = _FakeRepository();
    await tester.pumpWidget(_app(_fixture(), repo: repo));
    await tester.pumpAndSettle();

    final DateTime target = Dates.addDays(Dates.today(), -3);

    // The stray mark is Absent; tapping Absent on that row should clear it
    // rather than write the same value again.
    final Finder row = find.ancestor(
      of: find.text(Dates.formatFull(target)),
      matching: find.byType(SurfaceCard),
    );
    await tester.tap(
      find.descendant(
        of: row.first,
        matching: find.byIcon(AttendanceStatus.absent.icon),
      ),
    );
    await tester.pumpAndSettle();

    expect(repo.written, isEmpty);
    expect(
      repo.cleared.single,
      AttendanceRecord.keyFor(1, target, 15 * 60),
    );
  });
}
