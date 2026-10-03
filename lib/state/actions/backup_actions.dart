import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/report_error.dart';
import '../../data/settings/app_settings.dart';
import '../../services/backup_folder.dart';
import '../../services/backup_service.dart';
import '../app_providers.dart';
import 'action_core.dart';

/// How a manual export ended.
enum BackupSave {
  saved,
  cancelled,

  /// The save dialog failed, so the backup went to the clipboard instead.
  onClipboard,
}

/// Backups: the manual export and restore, the folder they start in, and the
/// automatic daily copy.
class BackupActions {
  BackupActions(this._core);

  final ActionCore _core;

  Ref get _ref => _core.ref;

  BackupFolder get _folder => _ref.read(backupFolderProvider);

  /// Guards against a launch and a resume landing together while the first
  /// write is still in flight: two concurrent exports would race on the same
  /// filename.
  bool _autoBackupRunning = false;

  /// Writes today's automatic backup if one is due, then records when.
  ///
  /// Called on launch and resume rather than from [ActionCore.refresh],
  /// because a backup per mutation would serialise the whole database on every
  /// attendance tap for a freshness gain measured in hours.
  Future<void> maybeRunAutoBackup() async {
    if (_autoBackupRunning) return;
    final AppSettings? settings = _ref.read(settingsProvider).value;
    if (settings == null || !settings.autoBackupEnabled) return;

    _autoBackupRunning = true;
    try {
      final bool written = await _ref.read(backupServiceProvider).runAutoBackup(
            enabled: settings.autoBackupEnabled,
            lastAt: settings.lastAutoBackupAt,
            folderUri: settings.backupFolderUri,
          );
      if (!written) return;
      await _ref
          .read(settingsProvider.notifier)
          .save(settings.copyWith(lastAutoBackupAt: DateTime.now()));
    } catch (error, stack) {
      // A failed backup must not take the app down with it. The next launch
      // tries again, and the stamp is only written on success so a failure
      // does not count as today's backup.
      reportError(error, stack, where: 'auto backup');
    } finally {
      _autoBackupRunning = false;
    }
  }

  /// The folder the user picked, by name. Null when they backed out; throws
  /// when the folder cannot be used.
  Future<String?> chooseFolder() async {
    final String? previous = _ref.read(settingsProvider).value?.backupFolderUri;
    final BackupFile? picked = await _folder.choose(initialUri: previous);
    if (picked == null) return null;
    // Created now, not at the first backup, so a grant that cannot write
    // fails in front of the user rather than days later.
    await _folder.resolveFolder(picked.uri);
    await _ref
        .read(settingsProvider.notifier)
        .setBackupFolder(picked.uri, picked.name);
    _ref.invalidate(backupFolderUsableProvider);
    // The old grant is no use once replaced, and Android caps how many an app
    // may hold.
    if (previous != null &&
        BackupFolder.treeUriOf(previous) !=
            BackupFolder.treeUriOf(picked.uri)) {
      await _release(previous, where: 'releasing the old backup folder');
    }
    return picked.name;
  }

  Future<void> clearFolder() async {
    final String? uri = _ref.read(settingsProvider).value?.backupFolderUri;
    if (uri != null) await _release(uri, where: 'releasing the backup folder');
    await _ref.read(settingsProvider.notifier).clearBackupFolder();
    _ref.invalidate(backupFolderUsableProvider);
  }

  /// A grant left behind costs one of the app's slots, not the change the user
  /// asked for, so it is reported rather than stopping it.
  Future<void> _release(String uri, {required String where}) async {
    try {
      await _folder.release(uri);
    } catch (error, stack) {
      reportError(error, stack, where: where);
    }
  }

  /// Where both dialogs start. Null leaves the picker wherever it was.
  Future<String?> _startFolder() async {
    final String? tree = _ref.read(settingsProvider).value?.backupFolderUri;
    if (tree == null) return null;
    try {
      return await _folder.resolveFolder(tree);
    } catch (_) {
      return null;
    }
  }

  /// Throws when the database cannot be read, which nothing here can fix.
  Future<String> buildBackup() =>
      _ref.read(backupServiceProvider).exportToJsonString();

  /// Saves through the system dialog so the file lands outside the app's own
  /// folder, which is deleted with the app. Falls back to the clipboard if the
  /// dialog fails — an awkward paste beats losing the export.
  Future<BackupSave> saveBackup(String json) async {
    try {
      final Uri? saved = await FilePicker.saveFile(
        dialogTitle: 'Save Zeolite backup',
        fileName: BackupService.fileNameFor(DateTime.now()),
        bytes: utf8.encode(json),
        mimeType: 'application/json',
        initialDirectory: await _startFolder(),
      );
      if (saved == null) return BackupSave.cancelled;
      unawaited(_ref.read(analyticsProvider).backupExported());
      return BackupSave.saved;
    } catch (error, stack) {
      reportError(error, stack, where: 'save dialog');
      await Clipboard.setData(ClipboardData(text: json));
      return BackupSave.onClipboard;
    }
  }

  /// Not `FilePicker`: its Android side never sets the initial-folder extra on
  /// an open dialog, so the starting folder would be ignored.
  Future<BackupFile?> pickBackup() async =>
      _folder.pickFile(initialUri: await _startFolder());

  /// Reads bytes rather than a path: a document-picker file is a `content://`
  /// URI with no path at all.
  Future<ImportResult> restore(BackupFile file) async {
    final ImportResult result;
    try {
      final String json = utf8.decode(await _folder.readBytes(file.uri));
      result =
          await _ref.read(backupServiceProvider).importFromJsonString(json);
    } catch (error, stack) {
      reportError(error, stack, where: 'reading a backup file');
      return const ImportResult(ImportOutcome.unreadable);
    }
    if (result.success) await _core.reloadAfterImport();
    return result;
  }
}

final backupActionsProvider = Provider<BackupActions>(
  (ref) => BackupActions(ref.read(actionCoreProvider)),
);
