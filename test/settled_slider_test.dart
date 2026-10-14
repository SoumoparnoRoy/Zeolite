import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/widgets/common.dart';

void main() {
  testWidgets('a drag saves once, at the end, while the label follows it',
      (WidgetTester tester) async {
    final List<double> saved = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettledSlider(
            value: 0,
            onSettled: saved.add,
            builder: (BuildContext context,
                    double shown,
                    ValueChanged<double> onChanged,
                    ValueChanged<double> onChangeEnd) =>
                Column(
              children: <Widget>[
                Text('shown ${shown.round()}'),
                Slider(
                  value: shown,
                  max: 100,
                  divisions: 100,
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final TestGesture drag =
        await tester.startGesture(tester.getCenter(find.byType(Slider)));
    await drag.moveBy(const Offset(100, 0));
    await tester.pump();
    await drag.moveBy(const Offset(100, 0));
    await tester.pump();

    expect(saved, isEmpty);
    expect(find.text('shown 0'), findsNothing);

    await drag.up();
    await tester.pump();

    expect(saved, hasLength(1));
    expect(saved.single, greaterThan(50));
  });
}
