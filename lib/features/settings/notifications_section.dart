import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/time_picker.dart';
import '../../data/settings/app_settings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

import 'settings_rows.dart';

class NotificationsSection extends ConsumerWidget {
  const NotificationsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);
    final bool exactAlarms = ref.watch(exactAlarmsProvider).value ?? true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Notifications'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              SettingsSwitchRow(
                icon: settings.notificationsEnabled
                    ? Icons.notifications_outlined
                    : Icons.notifications_off_outlined,
                title: 'All notifications',
                subtitle: settings.notificationsEnabled
                    ? 'Individual types can be turned off below'
                    : 'Nothing is sent to your notification tray',
                value: settings.notificationsEnabled,
                onChanged: (bool v) async {
                  if (v) {
                    await ref.read(notificationsProvider).requestPermissions();
                  }
                  await controller
                      .save(settings.copyWith(notificationsEnabled: v));
                  await ref.read(actionsProvider).reloadAfterImport();
                },
              ),
              const Divider(indent: 58),
              SettingsSwitchRow(
                icon: Icons.chat_bubble_outline,
                title: 'Show alerts in the app',
                subtitle: settings.showDangerInApp
                    ? 'Attendance warnings appear here instead'
                    : 'Used when attendance alerts are switched off',
                value: settings.inAppAlerts,
                onChanged: (bool v) async {
                  await controller.save(settings.copyWith(inAppAlerts: v));
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Opacity(
          // The per-type rows stay readable but inert while the master
          // switch is off, so it is obvious why they do nothing.
          opacity: settings.notificationsEnabled ? 1 : 0.4,
          child: IgnorePointer(
            ignoring: !settings.notificationsEnabled,
            child: SurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  SettingsSwitchRow(
                    icon: Icons.notifications_active_outlined,
                    title: 'Before each class',
                    subtitle:
                        '${settings.notifyLeadMinutes} minutes before it starts',
                    value: settings.notifyBeforeClass,
                    onChanged: (bool v) async {
                      if (v) {
                        await ref
                            .read(notificationsProvider)
                            .requestPermissions();
                      }
                      await controller
                          .save(settings.copyWith(notifyBeforeClass: v));
                      await ref.read(actionsProvider).reloadAfterImport();
                    },
                    onTapSubtitle: settings.notifyBeforeClass
                        ? () =>
                            _pickLeadTime(context, controller, settings, ref)
                        : null,
                  ),
                  const Divider(indent: 58),
                  SettingsSwitchRow(
                    icon: Icons.task_alt_rounded,
                    title: 'When each class ends',
                    subtitle: 'Mark it from the notification',
                    value: settings.notifyAtClassEnd,
                    onChanged: (bool v) async {
                      if (v) {
                        await ref
                            .read(notificationsProvider)
                            .requestPermissions();
                      }
                      await controller
                          .save(settings.copyWith(notifyAtClassEnd: v));
                      await ref.read(actionsProvider).reloadAfterImport();
                    },
                  ),
                  if (settings.classRemindersActive ||
                      settings.classEndRemindersActive) ...<Widget>[
                    const Divider(indent: 58),
                    SettingsRow(
                      icon: Icons.timer_outlined,
                      title: 'Exact timing',
                      value: exactAlarms
                          ? 'Reminders arrive on the minute'
                          : 'Off — a reminder can be a few minutes late',
                      onTap: () => _requestExactAlarms(context, ref),
                    ),
                  ],
                  const Divider(indent: 58),
                  SettingsSwitchRow(
                    icon: Icons.edit_calendar_outlined,
                    title: 'Evening reminder',
                    subtitle:
                        'Mark unmarked classes at ${Clock.format(settings.eveningReminderMinutes, use24Hour: settings.use24HourTime)}',
                    value: settings.notifyEveningReminder,
                    onChanged: (bool v) async {
                      if (v) {
                        await ref
                            .read(notificationsProvider)
                            .requestPermissions();
                      }
                      await controller
                          .save(settings.copyWith(notifyEveningReminder: v));
                      await ref.read(actionsProvider).reloadAfterImport();
                    },
                    onTapSubtitle: settings.notifyEveningReminder
                        ? () =>
                            _pickEveningTime(context, controller, settings, ref)
                        : null,
                  ),
                  const Divider(indent: 58),
                  SettingsSwitchRow(
                    icon: Icons.warning_amber_rounded,
                    title: 'Attendance alerts',
                    subtitle: settings.showDangerInApp
                        ? 'Off — shown in the app instead'
                        : 'Warn me when a subject nears the limit',
                    value: settings.notifyAttendanceDanger,
                    onChanged: (bool v) async {
                      if (v) {
                        await ref
                            .read(notificationsProvider)
                            .requestPermissions();
                      }
                      await controller
                          .save(settings.copyWith(notifyAttendanceDanger: v));
                      await ref.read(actionsProvider).reloadAfterImport();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickLeadTime(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
    WidgetRef ref,
  ) async {
    const List<int> options = <int>[5, 10, 15, 20, 30, 45, 60];
    final int? picked = await showAppSheet<int>(
      context: context,
      title: 'Remind me before class',
      child: Column(
        children: <Widget>[
          for (final int minutes in options)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('$minutes minutes before'),
              trailing: settings.notifyLeadMinutes == minutes
                  ? Icon(Icons.check_rounded, color: context.palette.accent)
                  : null,
              onTap: () => Navigator.of(context).pop(minutes),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await controller.save(settings.copyWith(notifyLeadMinutes: picked));
    await ref.read(actionsProvider).reloadAfterImport();
  }

  Future<void> _pickEveningTime(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
    WidgetRef ref,
  ) async {
    final TimeOfDay? picked = await showAppTimePicker(
      context,
      initialTime: TimeOfDay(
        hour: Clock.hourOf(settings.eveningReminderMinutes),
        minute: Clock.minuteOf(settings.eveningReminderMinutes),
      ),
      use24Hour: settings.use24HourTime,
    );
    if (picked == null) return;
    await controller.save(
      settings.copyWith(
        eveningReminderMinutes: Clock.toMinutes(picked.hour, picked.minute),
      ),
    );
    await ref.read(actionsProvider).reloadAfterImport();
  }

  /// Android owns the decision, so the app opens the screen and re-reads the
  /// answer once it closes.
  Future<void> _requestExactAlarms(BuildContext context, WidgetRef ref) async {
    await ref.read(notificationsProvider).requestExactAlarms();
    ref.invalidate(exactAlarmsProvider);
    await ref.read(actionsProvider).refreshNotifications();
  }
}
