import 'dart:convert';
import 'dart:typed_data';

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
import 'package:zeolite/domain/notion_export.dart';
import 'package:zeolite/features/subjects/notion_import_screen.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => AppSettings(
        onboarded: true,
        semesterStart: Dates.addDays(Dates.today(), -60),
        semesterEnd: Dates.addDays(Dates.today(), 60),
      );
}

final DateTime _day = Dates.addDays(Dates.today(), -7);

String _dayCell(DateTime date) =>
    '${_months[date.month - 1]} ${date.day}';

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The lab is stored and already marked; the course it belongs to is not
/// stored at all. So nothing conflicts until the courses are split apart.
TimetableData _fixture() => TimetableData(
      categories: const <ClassCategory>[],
      subjects: const <Subject>[
        Subject(id: 1, name: 'Thermodynamics Lab', colorValue: 0xFF7C6BFF),
      ],
      slots: const <ClassSlot>[],
      extras: const <ExtraClass>[],
      holidays: const <Holiday>[],
      records: <AttendanceRecord>[
        AttendanceRecord(
          subjectId: 1,
          date: _day,
          startMinutes: 9 * 60,
          status: AttendanceStatus.present,
        ),
      ],
    );

NotionExport _export() {
  final String csv = <String>[
    'Name,Attendance Credit (1/2/0),Course,Date,Held (1/2/0),Held?,L/T/P,Status',
    'ABC101L,1,Thermodynamics,${_dayCell(_day)},1,Yes,Lecture,Present',
    'ABC101P,2,Thermodynamics,${_dayCell(Dates.addDays(_day, 1))},2,Yes,'
        'Practical,Present',
  ].join('\n');
  return NotionExport.read(Uint8List.fromList(utf8.encode(csv)));
}

Widget _app() => ProviderScope(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => _fixture()),
        settingsProvider.overrideWith(_StaticSettings.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: NotionImportScreen(export: _export()),
      ),
    );

void main() {
  testWidgets('grouped, the course is one new subject',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Thermodynamics'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('Bring in 2'), findsOneWidget);
  });

  testWidgets('a conflict that only exists once the courses are split '
      'still starts unticked', (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Seeded once for the screen, this arrived ticked and overwrote the mark.
    await tester.tap(find.text('Lecture and lab kept apart'));
    await tester.pumpAndSettle();

    expect(find.text('Thermodynamics Lab'), findsOneWidget);
    expect(find.text('CONFLICT'), findsOneWidget);
    expect(find.text('Bring in 1'), findsOneWidget);
  });

  testWidgets('a choice survives the grouping being flipped back',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Thermodynamics'));
    await tester.pumpAndSettle();
    expect(find.text('Bring in 2'), findsNothing);

    await tester.tap(find.text('Lecture and lab kept apart'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('One subject per course'));
    await tester.pumpAndSettle();

    // Still unticked, because it was the user who unticked it.
    expect(find.text('Bring in 2'), findsNothing);
  });
}
