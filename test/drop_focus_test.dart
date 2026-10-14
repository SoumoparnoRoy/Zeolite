import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/widgets/common.dart';

void main() {
  // Seen on the Pixel 9: after searching Settings, every sheet closed on
  // Today brought the keyboard back up for the search field.
  testWidgets('a dropped field does not take focus back when a sheet closes',
      (WidgetTester tester) async {
    final FocusNode field = FocusNode();
    addTearDown(field.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext c) {
              context = c;
              return TextField(focusNode: field);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    dropFocus();
    await tester.pump();
    expect(field.hasFocus, isFalse);

    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 100),
      ),
    );
    await tester.pumpAndSettle();
    Navigator.of(context).pop();
    await tester.pumpAndSettle();

    expect(field.hasFocus, isFalse);
  });
}
