import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/zeolite_repository.dart';
import '../../data/models/class_category.dart';
import '../../domain/sync/sync_merge.dart';
import '../../services/sync/sync_coordinator.dart';
import '../app_providers.dart';
import 'action_core.dart';

/// Whole-database actions: a first sync that had to be merged, and wiping
/// everything.
class DataActions {
  DataActions(this._core);

  final ActionCore _core;

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

final dataActionsProvider = Provider<DataActions>(
  (ref) => DataActions(ref.read(actionCoreProvider)),
);
