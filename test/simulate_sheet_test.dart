import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/features/stats/simulate_sheet.dart';

const Subject subject =
    Subject(id: 1, name: 'Subject 1', colorValue: 0xFF7C6BFF);

Future<void> pump(WidgetTester tester, SubjectStats stats) {
  return tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(child: SimulateSheet(stats: stats)),
      ),
    ),
  );
}

void main() {
  testWidgets('stepping Attend moves the figure and the verdict', (
    WidgetTester tester,
  ) async {
    // 2 of 4, so one more attended class takes it to 60% and still at risk.
    await pump(
      tester,
      const SubjectStats(
        subject: subject,
        present: 2,
        absent: 2,
        cancelled: 0,
        target: 0.75,
        plannedFromSlots: 20,
      ),
    );
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Now 50%'), findsOneWidget);
    expect(
      find.text('Attending the next 4 brings you back to target'),
      findsOneWidget,
    );

    await tester.tap(find.bySemanticsLabel('One more to Attend'));
    await tester.pump();
    expect(find.text('60%'), findsOneWidget);
    expect(find.text('Now 50%'), findsOneWidget);
    expect(
      find.text('Attending the next 3 brings you back to target'),
      findsOneWidget,
    );

    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);
  });

  testWidgets('stops at the classes the term still holds', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      const SubjectStats(
        subject: subject,
        present: 3,
        absent: 1,
        cancelled: 0,
        target: 0.75,
        plannedFromSlots: 2,
      ),
    );
    await tester.tap(find.bySemanticsLabel('One more to Attend'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('One more to Miss'));
    await tester.pump();

    expect(find.text('That is every class left this term.'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('One more to Attend'));
    await tester.pump();
    // 4 of 6 held: the third tap was refused.
    expect(find.text('67%'), findsOneWidget);
  });
}
