import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/db/zeolite_repository.dart';
import '../../data/models/class_category.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/sync/sync_merge.dart';
import '../../services/sync/sync_coordinator.dart';
import '../providers.dart';

/// Whole-database actions: the automatic backup, a first sync that had to be
/// merged, and wiping everything.
class DataActions {
  DataActions(this._core);

  final ActionCore _core;

  // backup -------------------------------------------------------------------

  /// Guards against the home screen's post-frame callback firing again while
  /// the first write is still in flight — it runs on every build, not only on
  /// launch, and two concurrent exports would race on the same filename.
  bool _autoBackupRunning = false;

  /// Writes today's automatic backup if one is due, then records when.
  ///
  /// Called from the home screen rather than from [ActionCore.refresh],
  /// because a backup per mutation would serialise the whole database on every
  /// attendance tap for a freshness gain measured in hours.
  Future<void> maybeRunAutoBackup() async {
    if (_autoBackupRunning) return;
    final AppSettings? settings = _core.ref.read(settingsProvider).value;
    if (settings == null || !settings.autoBackupEnabled) return;

    _autoBackupRunning = true;
    try {
      final bool written =
          await _core.ref.read(backupServiceProvider).runAutoBackup(
                enabled: settings.autoBackupEnabled,
                lastAt: settings.lastAutoBackupAt,
                folderUri: settings.backupFolderUri,
              );
      if (!written) return;
      await _core.ref
          .read(settingsProvider.notifier)
          .save(settings.copyWith(lastAutoBackupAt: DateTime.now()));
    } catch (error) {
      // A failed backup must not take the home screen down with it. The next
      // launch tries again, and the stamp is only written on success so a
      // failure does not count as today's backup.
      debugPrint('Zeolite: auto backup failed: $error');
    } finally {
      _autoBackupRunning = false;
    }
  }

  /// Runs the first sync against an account that already had data, with the
  /// merge screen's decisions.
  ///
  /// Lives here rather than on the screen so it lands under the same snapshot
  /// every other import does: a merge can restate history, and one Undo has to
  /// put all of it back — the rows brought down and the ones sent up alike.
  Future<SyncRunResult> applySyncMerge(
    SyncCoordinator coordinator,
    Map<String, SyncSide> decisions,
  ) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    final SyncRunResult result =
        await coordinator.run(force: true, merge: decisions);
    await _core.reloadAfterSync();
    _core.armMerge(before, coordinator.target.id);
    return result;
  }

  // admin ------------------------------------------------------------------

  Future<void> resetEverything() async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.clearAll();
    // Put back as on install: without them there is nothing to give a new
    // subject a type, which is what the type sent to Notion comes from.
    for (final ClassCategory category in ClassCategory.defaults) {
      await _core.repo.insertCategory(category);
    }
    await _core.ref.read(notificationsProvider).cancelAll();
    await _core.refresh();
    _core.arm(before);
  }
}
