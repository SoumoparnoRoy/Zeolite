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
import 'package:zeolite/features/timetable/import_screen.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  _StaticSettings(this.settings);

  final AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;
}

/// The real timetable's day, so block 5 is 12:30–13:20.
const AppSettings _settings = AppSettings(
  onboarded: true,
  dayStartMinutes: 9 * 60 + 10,
  dayEndMinutes: 16 * 60 + 30,
  blockMinutes: 50,
);

final TimetableData _empty = TimetableData(
  categories: const <ClassCategory>[],
  subjects: const <Subject>[],
  slots: const <ClassSlot>[],
  extras: <ExtraClass>[],
  holidays: const <Holiday>[],
  records: <AttendanceRecord>[],
);

Widget _app() {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => _empty),
      settingsProvider.overrideWith(() => _StaticSettings(_settings)),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: const ImportTimetableScreen(),
    ),
  );
}

/// The preview sits under an eight-line text field and a sliver list only
/// builds what fits, so the default surface never reaches it.
Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

Future<void> _paste(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a paste is shown back as the classes it would create',
      (WidgetTester tester) async {
    await _open(tester);

    await _paste(tester, 'ECE1102, Mo, 5, B204\nECE3311, Tu, 9');

    expect(find.text('MONDAY'), findsOneWidget);
    expect(find.text('TUESDAY'), findsOneWidget);
    expect(find.text('ECE1102'), findsOneWidget);
    expect(find.text('B204'), findsOneWidget);
    expect(find.text('12:30 pm – 1:20 pm'), findsOneWidget);
    expect(find.textContaining('2 classes'), findsOneWidget);
  });

  testWidgets('a broken line is named and blocks the import',
      (WidgetTester tester) async {
    await _open(tester);

    await _paste(tester, 'ECE1102, Mo, 5\nECE1102, Moon, 1');

    expect(find.text('Line 2'), findsOneWidget);
    expect(find.textContaining('Moon'), findsWidgets);
    // The good line still previews; only the button is withheld.
    expect(find.text('ECE1102'), findsOneWidget);
    expect(find.textContaining('Add 1 to my timetable'), findsNothing);
  });

  testWidgets('nothing is offered until something parses',
      (WidgetTester tester) async {
    await _open(tester);
    expect(find.textContaining('to my timetable'), findsNothing);

    await _paste(tester, 'ECE1102, Mo, 5');
    expect(find.textContaining('Add 1 to my timetable'), findsOneWidget);
  });
}
