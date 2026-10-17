import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/widgets/common.dart';

void main() {
  // The account's rules refuse anything longer, failing every later sync.
  testWidgets('a name stops at the length the account accepts',
      (WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
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
    final Future<String?> result = showModalBottomSheet<String>(
      context: context,
      builder: (_) =>
          const SheetTextForm(submitLabel: 'Save', labelText: 'Room'),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'B' * (shortTextLimit + 50));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(await result, 'B' * shortTextLimit);
  });
}
