import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/tag.dart';
import 'package:zeolite/widgets/tag_picker.dart';

void main() {
  // A name can run to the 500-unit cap, far wider than a phone.
  testWidgets('a long tag name fits its chip and the chip can still be picked',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final String long = 'Online ' * 40;
    final Future<int?> picked = showTagPicker(
      context,
      tags: <Tag>[Tag(id: 7, name: long)],
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.sell_outlined));
    await tester.pumpAndSettle();
    expect(await picked, 7);
  });
}
