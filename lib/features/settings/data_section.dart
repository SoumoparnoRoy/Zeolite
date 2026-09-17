import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../data/settings/app_settings.dart';
import '../../services/backup_folder.dart';
import '../../services/backup_service.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/undo_snack.dart';

import 'settings_rows.dart';

class DataSection extends ConsumerWidget {
  const DataSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);
    final bool folderUsable =
        ref.watch(backupFolderUsableProvider).value ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Your data'),
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
                        onPressed: () =>
                            _clearBackupFolder(context, ref, settings),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        color: context.palette.textTertiary,
                      )
                    : null,
              ),
              const Divider(indent: 58),
              SettingsRow(
                icon: Icons.delete_forever_outlined,
                title: 'Reset everything',
                value: 'Delete all subjects and history',
                danger: true,
                onTap: () => _reset(context, ref),
              ),
            ],
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
    try {
      final BackupFolder folder = BackupFolder();
      final BackupFile? picked = await folder.choose(
        initialUri: ref.read(settingsProvider).value?.backupFolderUri,
      );
      if (picked == null) return;
      // Created now, not at the first backup, so a grant that cannot write
      // fails in front of the user rather than days later.
      await folder.resolveFolder(picked.uri);
      await ref
          .read(settingsProvider.notifier)
          .setBackupFolder(picked.uri, picked.name);
      ref.invalidate(backupFolderUsableProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Automatic backups go to ${picked.name} from now on'),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not use that folder')),
      );
    }
  }

  Future<void> _clearBackupFolder(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final String? uri = settings.backupFolderUri;
    if (uri != null) {
      try {
        await BackupFolder().release(uri);
      } catch (_) {}
    }
    await ref.read(settingsProvider.notifier).clearBackupFolder();
    ref.invalidate(backupFolderUsableProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Automatic backups go to the app's own folder again."),
      ),
    );
  }

  /// Where both dialogs start. Null leaves the picker wherever it was.
  static Future<String?> _backupFolderUri(WidgetRef ref) async {
    final String? tree = ref.read(settingsProvider).value?.backupFolderUri;
    if (tree == null) return null;
    try {
      return await BackupFolder().resolveFolder(tree);
    } catch (_) {
      return null;
    }
  }

  /// Saves through the system dialog so the file lands outside the app's own
  /// folder, which is deleted with the app. Falls back to the clipboard if the
  /// dialog fails — an awkward paste beats losing the export.
  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final BackupService backup = ref.read(backupServiceProvider);
    try {
      final String json = await backup.exportToJsonString();
      final Uri? saved = await FilePicker.saveFile(
        dialogTitle: 'Save Zeolite backup',
        fileName: BackupService.fileNameFor(DateTime.now()),
        bytes: utf8.encode(json),
        mimeType: 'application/json',
        initialDirectory: await _backupFolderUri(ref),
      );
      if (!context.mounted) return;

      if (saved == null) {
        // Cancelled. Saying nothing would look like a failure.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export cancelled')),
        );
        return;
      }
      unawaited(ref.read(analyticsProvider).backupExported());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup saved')),
      );
    } catch (error) {
      debugPrint('Zeolite: save dialog failed: $error');
      final String json = await backup.exportToJsonString();
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the save dialog. '
              'The backup is on your clipboard instead.'),
          duration: Duration(seconds: 6),
        ),
      );
    }
  }

  /// Confirms before restoring, because the file dialog made this two taps from
  /// the Settings list and it replaces everything. Reads bytes rather than a
  /// path: a document-picker file is a `content://` URI with no path at all.
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final BackupFolder folder = BackupFolder();
    // Not `FilePicker`: its Android side never sets the initial-folder extra
    // on an open dialog, so the starting folder below would be ignored.
    final BackupFile? picked =
        await folder.pickFile(initialUri: await _backupFolderUri(ref));
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
    if (confirmed != true) return;

    late final ImportResult result;
    try {
      final String json = utf8.decode(await folder.readBytes(picked.uri));
      result = await ref.read(backupServiceProvider).importFromJsonString(json);
    } catch (error) {
      debugPrint('Zeolite: backup file unreadable: $error');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read that file.')),
      );
      return;
    }

    if (result.success) {
      await ref.read(actionCoreProvider).reloadAfterImport();
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }

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
