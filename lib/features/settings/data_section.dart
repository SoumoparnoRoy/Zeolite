import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/report_error.dart';
import '../../core/words.dart';
import '../../data/models/attendance_record.dart';
import '../../data/settings/app_settings.dart';
import '../../services/backup_folder.dart';
import '../../services/backup_service.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/undo_snack.dart';

import 'settings_rows.dart';
import 'untimed_match_screen.dart';

class DataSection extends ConsumerWidget {
  const DataSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);
    final bool folderUsable =
        ref.watch(backupFolderUsableProvider).value ?? false;
    final bool anyUntimed = ref.watch(timetableProvider).value?.records.any(
              (AttendanceRecord r) => !AttendanceRecord.isTimed(r.startMinutes),
            ) ??
        false;
    final int matchable = ref.watch(untimedMatchesProvider).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              SettingsRow(
                icon: Icons.ios_share_rounded,
                title: 'Export backup',
                value: 'Save a JSON file',
                onTap: () => _export(context, ref),
              ),
              const Divider(indent: 58),
              SettingsRow(
                icon: Icons.download_rounded,
                title: 'Import backup',
                value: 'Restore from a file',
                onTap: () => _import(context, ref),
              ),
              const Divider(indent: 58),
              SettingsSwitchRow(
                icon: Icons.backup_outlined,
                title: 'Automatic backup',
                subtitle: settings.autoBackupEnabled
                    ? 'Once a day, keeping the last '
                        '${BackupService.keepAutoBackups}'
                    : 'Off',
                value: settings.autoBackupEnabled,
                onChanged: (bool v) =>
                    controller.save(settings.copyWith(autoBackupEnabled: v)),
              ),
              const Divider(indent: 58),
              SettingsRow(
                icon: Icons.folder_outlined,
                title: 'Backup folder',
                value: _backupFolderLine(settings, folderUsable),
                onTap: () => _pickBackupFolder(context, ref),
                trailing: settings.hasBackupFolder
                    ? IconButton(
                        onPressed: () => _clearBackupFolder(context, ref),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        color: context.palette.textTertiary,
                      )
                    : null,
              ),
              if (anyUntimed) ...<Widget>[
                const Divider(indent: 58),
                SettingsRow(
                  icon: Icons.schedule_rounded,
                  title: 'Match classes with no time',
                  value: matchable == 0
                      ? 'Nothing to match yet'
                      : '${Words.plural(matchable, 'class', 'classes')} can be '
                          'matched',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: 'untimed_match'),
                      builder: (_) => const UntimedMatchScreen(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: SettingsRow(
            icon: Icons.delete_forever_outlined,
            title: 'Reset everything',
            value: 'Delete all subjects and history',
            danger: true,
            onTap: () => _reset(context, ref),
          ),
        ),
      ],
    );
  }

  /// The unavailable case is not silent: a backup still happens, and this row
  /// is where the user finds out where it went.
  static String _backupFolderLine(AppSettings settings, bool usable) {
    if (!settings.hasBackupFolder) {
      return "App's own folder — removed with the app";
    }
    final String name = settings.backupFolderName?.isNotEmpty ?? false
        ? settings.backupFolderName!
        : 'Chosen folder';
    if (!usable) return "$name is unavailable — using the app's own folder";
    return name == BackupFolder.folderName
        ? name
        : '$name/${BackupFolder.folderName}';
  }

  Future<void> _pickBackupFolder(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final String? name = await ref.read(backupActionsProvider).chooseFolder();
      if (name == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Automatic backups go to $name from now on')),
      );
    } catch (error, stack) {
      reportError(error, stack, where: 'choosing a backup folder');
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not use that folder.')),
      );
    }
  }

  Future<void> _clearBackupFolder(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await ref.read(backupActionsProvider).clearFolder();
    messenger.showSnackBar(
      const SnackBar(
        content: Text("Automatic backups go to the app's own folder again"),
      ),
    );
  }

  /// Built before the dialog, so the clipboard fallback never repeats a step
  /// that just failed.
  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final BackupActions backups = ref.read(backupActionsProvider);
    final String json;
    try {
      json = await backups.buildBackup();
    } catch (error, stack) {
      reportError(error, stack, where: 'backup export');
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not create the backup.')),
      );
      return;
    }
    messenger.showSnackBar(
      switch (await backups.saveBackup(json)) {
        BackupSave.saved => const SnackBar(content: Text('Backup saved')),
        // Saying nothing would look like a failure.
        BackupSave.cancelled =>
          const SnackBar(content: Text('Export cancelled')),
        BackupSave.onClipboard => const SnackBar(
            content: Text('Could not open the save dialog. '
                'The backup is on your clipboard instead.'),
            duration: Duration(seconds: 6),
          ),
      },
    );
  }

  /// Confirms before restoring, because the file dialog made this two taps from
  /// the Settings list and it replaces everything.
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final BackupActions backups = ref.read(backupActionsProvider);
    final BackupFile? picked = await backups.pickBackup();
    if (picked == null || !context.mounted) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Restore this backup?'),
        content: const Text(
          'Everything currently in the app is replaced by the contents of '
          'the file. This cannot be undone.',
          style: TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ImportResult result = await backups.restore(picked);
    messenger.showSnackBar(
      SnackBar(content: Text(_restoreMessage(result.outcome))),
    );
  }

  static String _restoreMessage(ImportOutcome outcome) => switch (outcome) {
        ImportOutcome.restored => 'Backup restored',
        ImportOutcome.notABackup => 'That does not look like a Zeolite backup.',
        ImportOutcome.notJson => 'Could not read that as JSON.',
        ImportOutcome.notZeolite => 'This file was not created by Zeolite.',
        ImportOutcome.tooNew =>
          'This backup came from a newer version of Zeolite.',
        ImportOutcome.unreadable => 'Could not read that file.',
        ImportOutcome.failed => 'Could not restore this backup.',
      };

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Delete everything?'),
        content: const Text(
          'Every subject, class and attendance mark will be removed. '
          'Undo puts it straight back, but only until you change something '
          'else — export a backup first if you want a copy that keeps.',
          style: TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style:
                TextButton.styleFrom(foregroundColor: context.palette.absent),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ActionCore core = ref.read(actionCoreProvider);
    final DataActions data = ref.read(dataActionsProvider);
    await data.resetEverything();
    showUndoSnack(messenger, core, 'All data deleted');
  }
}
