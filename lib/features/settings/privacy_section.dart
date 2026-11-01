import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings/app_settings.dart';
import '../../state/auth_providers.dart';
import '../../state/privacy_providers.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../launch/first_run_choices_screen.dart';

import 'settings_rows.dart';

/// The age answer and, for an adult, the two collection choices, changeable
/// here after the first run asked them.
class PrivacySection extends ConsumerWidget {
  const PrivacySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final PrivacyChoices choices = ref.read(privacyChoicesProvider);
    final bool adult = settings.adult == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GroupedRows(
          children: <Widget>[
            SettingsSwitchRow(
              icon: Icons.cake_outlined,
              title: '18 or older',
              subtitle: adult
                  ? 'Accounts, Notion and the AI check are available'
                  : 'Everything stays on this device',
              value: adult,
              onChanged: (bool value) => value
                  ? choices.setAdult(true, fromSettings: true)
                  : _confirmUnder18(context, ref),
            ),
            // Hidden rather than shown off: under 18 there is no choice to
            // make, since nothing is collected either way.
            if (adult) ...<Widget>[
              SettingsSwitchRow(
                icon: Icons.insights_outlined,
                title: FirstRunChoicesScreen.usageTitle,
                subtitle: FirstRunChoicesScreen.usageLine,
                value: settings.shareUsage == true,
                onChanged: choices.setShareUsage,
              ),
              SettingsSwitchRow(
                icon: Icons.bug_report_outlined,
                title: FirstRunChoicesScreen.crashesTitle,
                subtitle: FirstRunChoicesScreen.crashesLine,
                value: settings.sendCrashReports == true,
                onChanged: choices.setSendCrashReports,
              ),
            ],
          ],
        ),
        GroupNote(adult
            ? 'Turning either off stops it straight away.'
            : 'Nothing is measured, synced or sent to the server.'),
      ],
    );
  }

  /// Only asked when there is an account to lose; otherwise the switch alone
  /// says what happens.
  static Future<void> _confirmUnder18(
      BuildContext context, WidgetRef ref) async {
    final PrivacyChoices choices = ref.read(privacyChoicesProvider);
    if (ref.read(signedInUserProvider).value == null) {
      return choices.setAdult(false);
    }
    final bool? yes = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Sign out and keep everything here?'),
        content: const Text(
          'Under 18, Zeolite signs you out and stops syncing. Your timetable '
          'and attendance stay on this device.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (yes == true) await choices.setAdult(false);
  }
}
