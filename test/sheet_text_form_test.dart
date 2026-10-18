import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/widgets/common.dart';

/// What a room sheet opened on [initial] hands back after [typed] is entered
/// and saved, with [composing] still being composed by the keyboard when Save
/// is tapped.
Future<String?> _saved(
  WidgetTester tester,
  String typed, {
  String initial = '',
  String? composing,
}) async {
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
    builder: (_) => SheetTextForm(
      submitLabel: 'Save',
      labelText: 'Room',
      initial: initial,
    ),
  );
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField), typed);
  if (composing != null) {
    final String text = typed + composing;
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange(start: typed.length, end: text.length),
    ));
    await tester.pump();
  }
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  // The account's rules refuse anything longer, failing every later sync.
  testWidgets('a name stops at the length the account accepts',
      (WidgetTester tester) async {
    expect(
      await _saved(tester, 'B' * (shortTextLimit + 50)),
      'B' * shortTextLimit,
    );
  });

  // The rules count UTF-16 units, and an emoji family is eight of them.
  testWidgets(
      'the length is counted as the account counts it, whole emoji '
      'kept whole', (WidgetTester tester) async {
    const String family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
    final String? saved = await _saved(tester, 'a${family * 200}');

    expect(saved, 'a${family * 62}');
    expect(saved!.length, lessThanOrEqualTo(shortTextLimit));
  });

  // Save takes the text as it stands, so a word still underlined by the
  // keyboard has to be held to the cap as well.
  testWidgets('a word still being composed does not go past the cap',
      (WidgetTester tester) async {
    expect(
      await _saved(tester, 'B' * shortTextLimit, composing: 'word'),
      'B' * shortTextLimit,
    );
  });

  // A name that came in by import can be over the cap, and shortening it is
  // the only way it will sync.
  testWidgets('a name already over the cap can still be shortened',
      (WidgetTester tester) async {
    final String imported = 'B' * (shortTextLimit + 100);
    final String backspaced = imported.substring(1);
    expect(await _saved(tester, backspaced, initial: imported), backspaced);
  });
}
