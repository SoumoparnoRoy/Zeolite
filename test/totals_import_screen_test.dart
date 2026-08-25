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
import 'package:zeolite/domain/attendance_totals_ocr.dart';
import 'package:zeolite/features/subjects/totals_import_screen.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => AppSettings(
        onboarded: true,
        semesterStart: Dates.addDays(Dates.today(), -30),
        semesterEnd: Dates.addDays(Dates.today(), 60),
      );
}

/// Signals is stored and has two marks this term; Control Systems is stored
/// with nothing marked. Imaging is not stored at all.
TimetableData _fixture() {
  final DateTime day = Dates.addDays(Dates.today(), -3);
  return TimetableData(
    categories: const <ClassCategory>[],
    subjects: const <Subject>[
      Subject(id: 1, name: 'Signal Theory', colorValue: 0xFF7C6BFF),
      Subject(id: 2, name: 'Control Systems', colorValue: 0xFF7C6BFF),
    ],
    slots: const <ClassSlot>[],
    extras: const <ExtraClass>[],
    holidays: const <Holiday>[],
    records: <AttendanceRecord>[
      AttendanceRecord(
        subjectId: 1,
        date: day,
        startMinutes: 9 * 60,
        status: AttendanceStatus.present,
      ),
      AttendanceRecord(
        subjectId: 1,
        date: Dates.addDays(day, -1),
        startMinutes: 9 * 60,
        status: AttendanceStatus.absent,
      ),
    ],
  );
}

const List<TotalsRow> _rows = <TotalsRow>[
  TotalsRow(
    subject: 'Signal Theory',
    expectedTotal: 18,
    held: 16,
    attended: 14,
    printedPercent: 87.5,
  ),
  TotalsRow(
    subject: 'Control Systems',
    expectedTotal: 20,
    held: 19,
    attended: 16,
    printedPercent: 84.21,
  ),
  TotalsRow(
    subject: 'Imaging Lab',
    expectedTotal: 6,
    held: 6,
    attended: 5,
    printedPercent: 83.33,
  ),
];

Widget _app(AttendanceTotals totals) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => _fixture()),
      settingsProvider.overrideWith(_StaticSettings.new),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: TotalsImportScreen(totals: totals),
    ),
  );
}

void main() {
  testWidgets('a subject being marked here is flagged, not applied',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(const AttendanceTotals(rows: _rows)));
    await tester.pumpAndSettle();

    expect(find.text('CONFLICT'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget); // Imaging Lab
    expect(find.text('UPDATE'), findsOneWidget); // Control Systems

    // It says what would happen to the two marks rather than just refusing.
    expect(
      find.textContaining('You have marked 2 classes here'),
      findsOneWidget,
    );

    // Two of the three are ready; the conflict starts unticked.
    expect(find.text('Bring in 2'), findsOneWidget);
  });

  testWidgets('ticking the conflict brings it back in',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(const AttendanceTotals(rows: _rows)));
    await tester.pumpAndSettle();

    expect(find.text('Bring in 2'), findsOneWidget);
    await tester.tap(find.text('Signal Theory'));
    await tester.pumpAndSettle();

    expect(find.text('Bring in 3'), findsOneWidget);
  });

  testWidgets('a row that contradicts its own percentage starts out excluded',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const AttendanceTotals(
          rows: <TotalsRow>[
            // 14 of 18 is not 87.5%, so one of the three was misread.
            TotalsRow(
              subject: 'Imaging Lab',
              expectedTotal: 18,
              held: 18,
              attended: 14,
              printedPercent: 87.5,
            ),
            TotalsRow(
              subject: 'Optics',
              expectedTotal: 6,
              held: 6,
              attended: 5,
              printedPercent: 83.33,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('which these numbers do not give'),
        findsOneWidget);
    expect(find.text('Bring in 1'), findsOneWidget);
  });

  testWidgets('a row whose numbers went unread is shown, not hidden',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const AttendanceTotals(
          rows: <TotalsRow>[
            ..._rows,
            TotalsRow(
              subject: 'Thermodynamics',
              expectedTotal: null,
              held: 0,
              attended: 0,
              numbersUnread: true,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Thermodynamics'), findsOneWidget);
    expect(find.textContaining('numbers unread'), findsOneWidget);
    expect(
      find.textContaining('could not be read, so there is nothing to bring in'),
      findsOneWidget,
    );
    expect(find.text('Bring in 2'), findsOneWidget);
  });

  testWidgets('an unread row cannot be ticked back on',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const AttendanceTotals(
          rows: <TotalsRow>[
            ..._rows,
            TotalsRow(
              subject: 'Thermodynamics',
              expectedTotal: null,
              held: 0,
              attended: 0,
              numbersUnread: true,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bring in 2'), findsOneWidget);
    await tester.tap(find.text('Thermodynamics'));
    await tester.pumpAndSettle();

    // Letting this one through would write zeroes over a stored subject, so
    // the tap is ignored rather than merely discouraged.
    expect(find.text('Bring in 2'), findsOneWidget);
  });

  testWidgets('a page that does not add up says so before anything is applied',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const AttendanceTotals(
          rows: _rows,
          printedTotal: 60, // the rows come to 44
          printedAttended: 35,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('This does not add up'), findsOneWidget);
    expect(
      find.textContaining('sessions add to 44, the page says 60'),
      findsOneWidget,
    );
  });

  testWidgets('a page that adds up says nothing about it',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const AttendanceTotals(
          rows: _rows,
          printedTotal: 44,
          printedAttended: 35,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('This does not add up'), findsNothing);
  });
}
