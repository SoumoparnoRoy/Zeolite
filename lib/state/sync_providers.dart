import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/sync/sync_merge.dart';
import '../domain/sync/sync_status.dart';
import '../domain/sync/sync_target.dart';
import '../services/firebase/firestore_sync_target.dart';
import '../services/sync/sync_coordinator.dart';
import 'auth_providers.dart';
import 'providers.dart';

/// The account as somewhere to mirror to, or null while signed out. Rebuilt
/// when the user changes, so signing into a second account cannot go on
/// writing to the first one's collections.
final syncTargetProvider = Provider<SyncTarget?>((ref) {
  final User? user = ref.watch(signedInUserProvider).value;
  if (user == null) return null;
  return FirestoreSyncTarget(uid: user.uid);
});

final syncCoordinatorProvider = Provider<SyncCoordinator?>((ref) {
  final SyncTarget? target = ref.watch(syncTargetProvider);
  if (target == null) return null;
  return SyncCoordinator(
    repository: ref.watch(repositoryProvider),
    settings: ref.watch(settingsServiceProvider),
    target: target,
  );
});

final syncStatusProvider = NotifierProvider<SyncController, SyncStatus>(
  SyncController.new,
);

/// What Settings reads and what the Retry button calls.
///
/// Holds the last result as well as the status because the two answer
/// different questions — whether a run is in trouble, and what the last one
/// did — and a screen showing "synced" with no counts says very little.
class SyncController extends Notifier<SyncStatus> {
  SyncRunResult? _last;
  SyncRunResult? get lastResult => _last;

  @override
  SyncStatus build() {
    // Signing out has to clear this: a stale "synced 2 minutes ago" against an
    // account nobody is in reads as a promise the app is not keeping.
    ref.watch(syncTargetProvider);
    return const SyncStatus();
  }

  /// The merge screen's answer, applied. Routed through here rather than
  /// called on [TimetableActions] directly so the status card learns the run
  /// happened — otherwise Settings goes on offering a review of a difference
  /// that has already been settled.
  Future<SyncRunResult?> merge(Map<String, SyncSide> decisions) async {
    final SyncCoordinator? coordinator = ref.read(syncCoordinatorProvider);
    if (coordinator == null) return null;

    state = coordinator.status.running();
    final SyncRunResult result = await ref
        .read(actionsProvider)
        .applySyncMerge(coordinator, decisions);
    _last = result;
    state = coordinator.status;
    return result;
  }

  /// Never awaited by a write path. Marking has already succeeded locally by
  /// the time this runs, and a failure is a line in Settings, not a modal.
  Future<SyncRunResult?> run({bool force = false}) async {
    final SyncCoordinator? coordinator = ref.read(syncCoordinatorProvider);
    if (coordinator == null) return null;
    if (state.state == SyncState.running) return null;

    state = coordinator.status.running();
    final SyncRunResult result = await coordinator.run(force: force);
    _last = result;
    state = coordinator.status;
    return result;
  }
}
