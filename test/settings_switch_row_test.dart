import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/features/settings/settings_rows.dart';

Widget _row({required ValueChanged<bool> onChanged, VoidCallback? onEdit}) {
  return MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(
      body: SettingsSwitchRow(
        icon: Icons.notifications_outlined,
        title: 'Evening reminder',
        subtitle: 'At 9:00 PM',
        value: false,
        onChanged: onChanged,
        onTapSubtitle: onEdit,
      ),
    ),
  );
}

void main() {
  testWidgets('tapping the words flips the switch, not only the switch',
      (WidgetTester tester) async {
    final List<bool> changes = <bool>[];
    await tester.pumpWidget(_row(onChanged: changes.add));

    await tester.tap(find.text('Evening reminder'));
    expect(changes, <bool>[true]);
  });

  testWidgets('a row whose subtitle opens something keeps that tap',
      (WidgetTester tester) async {
    final List<bool> changes = <bool>[];
    int edits = 0;
    await tester.pumpWidget(
      _row(onChanged: changes.add, onEdit: () => edits++),
    );

    await tester.tap(find.text('Evening reminder'));
    expect(edits, 1);
    expect(changes, isEmpty);
  });
}
