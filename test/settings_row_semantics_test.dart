import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/features/settings/settings_rows.dart';
import 'package:zeolite/widgets/common.dart';

/// The Account page's shape, as one list item as there. The item's node takes
/// in any text below it that has no node of its own, which is how TalkBack
/// read the whole page as one stop.
Widget _page({required bool autoSync, VoidCallback? onDelete}) {
  return MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(
      body: ListView(
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SectionHeader('Signed in as'),
              SettingsNoted(
                note: 'A note about the card above.',
                child: GroupedRows(
                  children: <Widget>[
                    const SettingsRow(
                      icon: Icons.person_outline_rounded,
                      title: 'user1@example.com',
                      value: 'Backups go to this account',
                    ),
                    SettingsRow(
                      icon: Icons.logout_rounded,
                      title: 'Sign out',
                      value: 'Attendance on this device stays here',
                      onTap: () {},
                      semanticsIdentifier: 'sign-out',
                    ),
                  ],
                ),
              ),
              const SectionHeader('Sync'),
              SettingsNoted(
                note: 'A note about the sync card.',
                child: GroupedRows(
                  children: <Widget>[
                    SettingsRow(
                      icon: Icons.schedule_rounded,
                      title: 'Sync automatically',
                      value: 'About 15 seconds after you mark a class',
                      onTap: () {},
                      trailing: Switch(value: autoSync, onChanged: (_) {}),
                      mergeTrailing: true,
                    ),
                    SettingsRow(
                      icon: Icons.delete_forever_outlined,
                      title: 'Delete my account',
                      value: 'Available once the sync finishes',
                      onTap: onDelete,
                      enabled: false,
                      semanticsIdentifier: 'delete-account',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('each settings row is one node of its own', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    int deletes = 0;
    await tester.pumpWidget(_page(autoSync: true, onDelete: () => deletes++));

    expect(
      tester.getSemantics(find.text('user1@example.com')).label,
      'user1@example.com\nBackups go to this account',
    );
    final SemanticsNode header = tester.getSemantics(find.text('SIGNED IN AS'));
    expect(header.label, 'SIGNED IN AS');
    expect(header.getSemanticsData().flagsCollection.isHeader, isTrue);
    expect(
      tester.getSemantics(find.text('A note about the card above.')).label,
      'A note about the card above.',
    );

    final SemanticsNode signOut =
        tester.getSemantics(find.bySemanticsIdentifier('sign-out'));
    expect(signOut.label, 'Sign out\nAttendance on this device stays here');
    expect(signOut.getSemanticsData().flagsCollection.isButton, isTrue);
    expect(signOut.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    final SemanticsNode sync =
        tester.getSemantics(find.text('Sync automatically'));
    expect(
      sync.label,
      'Sync automatically\nAbout 15 seconds after you mark a class',
    );
    expect(sync.getSemanticsData().flagsCollection.isToggled, Tristate.isTrue);

    final SemanticsData delete = tester
        .getSemantics(find.bySemanticsIdentifier('delete-account'))
        .getSemanticsData();
    expect(delete.flagsCollection.isButton, isTrue);
    expect(delete.flagsCollection.isEnabled, Tristate.isFalse);
    await tester.tap(find.text('Delete my account'));
    expect(deletes, 0);

    handle.dispose();
  });

  testWidgets('a switch row says which setting its switch is', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              Column(
                children: <Widget>[
                  SettingsSwitchRow(
                    icon: Icons.notifications_outlined,
                    title: 'All notifications',
                    subtitle: 'Individual types can be turned off below',
                    value: true,
                    onChanged: (_) {},
                  ),
                  SettingsSwitchRow(
                    icon: Icons.notifications_active_outlined,
                    title: 'Before each class',
                    subtitle: '15 minutes before it starts',
                    value: false,
                    onChanged: (_) {},
                    onTapSubtitle: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final SemanticsData all =
        tester.getSemantics(find.text('All notifications')).getSemanticsData();
    expect(all.label,
        'All notifications\nIndividual types can be turned off below');
    expect(all.flagsCollection.isToggled, Tristate.isTrue);

    // The subtitle opens the lead time, so the switch is a stop of its own.
    final SemanticsData before =
        tester.getSemantics(find.byType(Switch).last).getSemanticsData();
    expect(before.label, 'Before each class');
    expect(before.flagsCollection.isToggled, Tristate.isFalse);

    handle.dispose();
  });
}
