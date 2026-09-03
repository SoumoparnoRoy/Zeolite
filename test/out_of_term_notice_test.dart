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
import 'package:zeolite/features/stats/stats_screen.dart';
import 'package:zeolite/state/providers.dart';

/// The screen has to say out loud that marks are being left out of it. Silence
/// here is the whole defect: the figures read as if the marks did not exist.
final DateTime _start = DateTime(2026, 8, 18);
final DateTime _end = DateTime(2026, 12, 16);

class _Settings extends SettingsController {
  _Settings(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AttendanceRecord _on(DateTime date) => AttendanceRecord(
      subjectId: 1,
      date: date,
      startMinutes: 540,
      status: AttendanceStatus.present,
    );

TimetableData _data(List<AttendanceRecord> records) => TimetableData(
      categories: const <ClassCategory>[],
      subjects: const <Subject>[
        Subject(id: 1, name: 'Physics', colorValue: AppColors.defaultSubjectColor),
      ],
      slots: const <ClassSlot>[],
      extras: const <ExtraClass>[],
      holidays: const <Holiday>[],
      records: records,
    );

Widget _host(List<AttendanceRecord> records, AppSettings settings) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => _data(records)),
      settingsProvider.overrideWith(() => _Settings(settings)),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const StatsScreen()),
  );
}

void main() {
  final AppSettings term =
      AppSettings(semesterStart: _start, semesterEnd: _end, onboarded: true);

  testWidgets('names the marks it is leaving out, and offers both ways out',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(<AttendanceRecord>[
        _on(DateTime(2026, 8, 4)),
        _on(DateTime(2026, 8, 5)),
        _on(_start),
      ], term),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('2 marks outside your term'), findsOneWidget);
    expect(find.textContaining('not counted'), findsOneWidget);
    expect(find.text('Count them'), findsOneWidget);
    expect(find.text('Widen term'), findsOneWidget);
  });

  testWidgets('says so once they are being counted, and offers the way back',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        <AttendanceRecord>[_on(DateTime(2026, 8, 4))],
        term.copyWith(countOutsideTerm: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('They are counted below'), findsOneWidget);
    expect(find.text('Leave them out'), findsOneWidget);
  });

  testWidgets('stays out of the way when every mark is inside the term',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(<AttendanceRecord>[_on(_start)], term));
    await tester.pumpAndSettle();

    expect(find.textContaining('outside your term'), findsNothing);
  });
}
