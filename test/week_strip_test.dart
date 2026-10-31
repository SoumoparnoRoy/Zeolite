import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/features/today/week_strip.dart';

Widget _host(double width) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: WeekStrip(selected: Dates.today(), onSelected: (_) {}),
          ),
        ),
      ),
    );

void main() {
  // Today as an off-screen tab while the display rotated.
  testWidgets('a strip squeezed to almost nothing lays out without error',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(30));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host(400));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('${Dates.today().day}'), findsOneWidget);
  });

  // A density change re-measures every pill while the old ones are on screen.
  testWidgets('the selected day stays in view when the width changes',
      (WidgetTester tester) async {
    final Finder selected = find.byWidgetPredicate(
        (Widget w) => w is Material && w.color == const Color(0xFFF2F2F7));

    for (final double width in <double>[411, 617, 411, 360]) {
      await tester.pumpWidget(_host(width));
      await tester.pumpAndSettle();
      expect(selected, findsOneWidget, reason: 'at $width');
      final Rect pill = tester.getRect(selected);
      expect(pill.left, greaterThanOrEqualTo(0), reason: 'at $width');
      expect(pill.right, lessThanOrEqualTo(width), reason: 'at $width');
    }
  });
}
