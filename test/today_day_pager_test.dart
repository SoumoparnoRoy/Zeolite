import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/today/today_screen.dart';
import 'package:zeolite/state/providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

const TimetableData _empty = TimetableData(
  categories: <ClassCategory>[],
  subjects: <Subject>[],
  slots: <ClassSlot>[],
  extras: <ExtraClass>[],
  holidays: <Holiday>[],
  records: <AttendanceRecord>[],
);

void main() {
  // A day pill tapped, then a swipe up the list straight away. The
  // swipe's touch stopped the page turn, and the pager slid back to the day
  // it was leaving while the header already showed the new one.
  testWidgets('a swipe up the list mid page turn still lands on the new day',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => _empty),
        settingsProvider.overrideWith(_StaticSettings.new),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: const TodayScreen()),
    ));
    await tester.pumpAndSettle();

    final PageController pages =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    final int from = pages.page!.round();
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(TodayScreen)));

    container
        .read(selectedDateProvider.notifier)
        .select(Dates.addDays(Dates.today(), 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(pages.page, lessThan(from + 0.5), reason: 'turn not half way yet');

    final TestGesture swipe =
        await tester.startGesture(tester.getCenter(find.byType(PageView)));
    for (int i = 0; i < 6; i++) {
      await swipe.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await swipe.up();
    await tester.pumpAndSettle();

    expect(pages.page, from + 1);
  });
}
