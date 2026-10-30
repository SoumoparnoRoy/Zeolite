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
}
