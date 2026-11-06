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
import 'package:zeolite/domain/timetable_import.dart';
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

Widget _app({TimetableData? data}) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => data ?? _empty),
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
Future<void> _open(WidgetTester tester, {TimetableData? data}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(data: data));
  await tester.pumpAndSettle();
}

Future<void> _paste(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

/// Holds the write open, the way a slow write does on a device.
class _HeldImport extends ImportActions {
  _HeldImport(super.core, this.gate);

  final Completer<void> gate;
  int calls = 0;

  @override
  Future<void> importTimetable(
    TimetableImportResult result, {
    bool weighByBlocks = false,
    Map<String, int>? into,
  }) {
    calls++;
    return gate.future;
  }
}

void main() {
  testWidgets('a double tap on Add imports once and closes one screen',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Completer<void> gate = Completer<void>();
    late _HeldImport held;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => _empty),
        settingsProvider.overrideWith(() => _StaticSettings(_settings)),
        importActionsProvider.overrideWith(
          (Ref ref) => held = _HeldImport(ref.read(actionCoreProvider), gate),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ImportTimetableScreen(),
              ),
            ),
            child: const Text('Below'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Below'));
    await tester.pumpAndSettle();
    await _paste(tester, 'GEN201, Mo, 5');

    // The button leaves on a scale-out, and it can still be tapped until that
    // ends. A second write doubled the import and the second pop left no route.
    final Offset add = tester.getCenter(find.text('Add 1 to my timetable'));
    await tester.tapAt(add);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(add);
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    expect(held.calls, 1);
    expect(find.text('Below'), findsOneWidget);
  });

  testWidgets('a paste is shown back as the classes it would create',
      (WidgetTester tester) async {
    await _open(tester);

    await _paste(tester, 'GEN201, Mo, 5, R201\nGEN203, Tu, 9');

    expect(find.text('MONDAY'), findsOneWidget);
    expect(find.text('TUESDAY'), findsOneWidget);
    expect(find.text('GEN201'), findsOneWidget);
    expect(find.text('R201'), findsOneWidget);
    expect(find.text('12:30 PM – 1:20 PM'), findsOneWidget);
    expect(find.textContaining('2 classes'), findsOneWidget);
  });

  testWidgets('a broken line is named and blocks the import',
      (WidgetTester tester) async {
    await _open(tester);

    await _paste(tester, 'GEN201, Mo, 5\nGEN201, Moon, 1');

    expect(find.text('Line 2'), findsOneWidget);
    expect(find.textContaining('Moon'), findsWidgets);
    // The good line still previews; only the button is withheld.
    expect(find.text('GEN201'), findsOneWidget);
    expect(find.textContaining('Add 1 to my timetable'), findsNothing);
  });

  testWidgets('nothing is offered until something parses',
      (WidgetTester tester) async {
    await _open(tester);
    expect(find.textContaining('to my timetable'), findsNothing);

    await _paste(tester, 'GEN201, Mo, 5');
    expect(find.textContaining('Add 1 to my timetable'), findsOneWidget);
  });

  testWidgets('a sheet code joins its subject, and a choice survives edits',
      (WidgetTester tester) async {
    await _open(
      tester,
      data: TimetableData(
        categories: const <ClassCategory>[],
        subjects: const <Subject>[
          Subject(id: 1, name: 'Course 1', code: 'GEN201L', colorValue: 0),
          Subject(id: 2, name: 'Course 2', colorValue: 0),
        ],
        slots: const <ClassSlot>[],
        extras: <ExtraClass>[],
        holidays: const <Holiday>[],
        records: <AttendanceRecord>[],
      ),
    );

    await _paste(tester, 'GEN201L, Mo, 5\nGEN203, Tu, 9');
    expect(find.text('Added to Course 1'), findsOneWidget);
    expect(find.text('New subject'), findsOneWidget);

    await tester.tap(find.text('GEN203').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Course 2').last);
    await tester.pumpAndSettle();
    await _paste(tester, 'GEN201L, Mo, 5\nGEN203, Tu, 9\nGEN203, We, 2');

    expect(find.text('Added to Course 2'), findsOneWidget);
    expect(find.text('New subject'), findsNothing);
  });
}
