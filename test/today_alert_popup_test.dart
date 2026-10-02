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
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/features/today/today_screen.dart';
import 'package:zeolite/services/notification_service.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

/// Stands in for the alert list, so a test can raise alerts at any point.
class _Alerts extends Notifier<List<SubjectStats>> {
  @override
  List<SubjectStats> build() => const <SubjectStats>[];

  void raise(List<SubjectStats> alerts) => state = alerts;
}

final NotifierProvider<_Alerts, List<SubjectStats>> _alerts =
    NotifierProvider<_Alerts, List<SubjectStats>>(_Alerts.new);

const Subject _subject = Subject(
  id: 1,
  name: 'Course 1',
  colorValue: AppColors.defaultSubjectColor,
);

const SubjectStats _below = SubjectStats(
  subject: _subject,
  present: 2,
  absent: 6,
  cancelled: 0,
  target: 0.75,
  plannedFromSlots: 4,
);

const TimetableData _timetable = TimetableData(
  categories: <ClassCategory>[],
  subjects: <Subject>[_subject],
  slots: <ClassSlot>[],
  extras: <ExtraClass>[],
  holidays: <Holiday>[],
  records: <AttendanceRecord>[],
);

Widget _host() {
  return ProviderScope(
    overrides: [
      timetableProvider.overrideWith((Ref ref) async => _timetable),
      settingsProvider.overrideWith(_StaticSettings.new),
      inAppAlertsProvider.overrideWith((Ref ref) => ref.watch(_alerts)),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const TodayScreen()),
  );
}

void main() {
  final String title = NotificationService.dangerTitle(1);

  testWidgets('an alert is raised once, and a rebuild does not repeat it',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(TodayScreen)));
    container.read(_alerts.notifier).raise(const <SubjectStats>[_below]);
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    // Switching views rebuilds the whole screen with the same alert standing.
    await tester.tap(find.byTooltip('Show the week grid'));
    await tester.pumpAndSettle();

    expect(find.text(title), findsNothing);
  });

  testWidgets('an alert that lands after the first frame is still raised',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(find.text(title), findsNothing);

    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(TodayScreen)));
    container.read(_alerts.notifier).raise(const <SubjectStats>[_below]);
    await tester.pumpAndSettle();

    expect(find.text(title), findsOneWidget);
  });
}
