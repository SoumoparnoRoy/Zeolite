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
import 'package:zeolite/features/stats/stats_screen.dart';
import 'package:zeolite/features/today/today_screen.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

/// One subject, nothing marked in the app, 12 of 18 carried in from a portal
/// and 20 classes all term. Every figure on screen has to come from the
/// balance, because there is no record anywhere to fall back on.
const TimetableData _carried = TimetableData(
  categories: <ClassCategory>[],
  subjects: <Subject>[
    Subject(
      id: 1,
      name: 'Physics',
      colorValue: AppColors.defaultSubjectColor,
      priorHeld: 18,
      priorAttended: 12,
      expectedTotal: 20,
    ),
  ],
  slots: <ClassSlot>[],
  extras: <ExtraClass>[],
  holidays: <Holiday>[],
  records: <AttendanceRecord>[],
);

Widget _host(Widget screen) {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => _carried),
      settingsProvider.overrideWith(_StaticSettings.new),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: screen),
  );
}

void main() {
  testWidgets('Stats counts the balance everywhere it counts marks',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const StatsScreen()));
    await tester.pumpAndSettle();

    // 12 of 18 is 67%, and the card must not read "0 of 18" beside it.
    expect(find.text('12 of 18 attended'), findsOneWidget);
    // Once on the card, once as the headline — both off the same balance.
    expect(find.text('67%'), findsWidgets);
    expect(find.textContaining('0 of 18'), findsNothing);

    // The header legend counts the same classes as the percentage above it.
    expect(find.text('12'), findsWidgets);
  });

  testWidgets('Stats names the portal figure once a term total is known',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const StatsScreen()));
    await tester.pumpAndSettle();

    // 12 of 20 rather than 12 of 18, and 2 classes still to come.
    expect(
      find.textContaining('Your portal will say 60%'),
      findsOneWidget,
    );
    expect(find.textContaining('2 classes still to come'), findsOneWidget);
  });

  testWidgets('Today leads with the carried figures too',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const TodayScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('12 attended of 18 held'), findsOneWidget);
  });
}
