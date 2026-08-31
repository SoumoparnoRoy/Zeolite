import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings/app_settings.dart';
import '../domain/sync/sync_merge.dart';
import '../domain/sync/sync_status.dart';
import '../domain/sync/sync_target.dart';
import '../services/firebase/firestore_sync_target.dart';
import '../services/sync/sync_coordinator.dart';
import '../services/sync/sync_scheduler.dart';
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

/// The two automatic triggers, alive only while signed in. Rebuilding on the
/// target means signing out disposes the lifecycle listener and cancels any
/// pending run, so a debounce armed by the last edit before signing out
/// cannot fire against an account nobody is in.
///
/// Watched by the root widget purely to keep it alive: a provider nobody reads
/// is never constructed, and a scheduler nobody constructs never schedules.
final syncSchedulerProvider = Provider<SyncScheduler?>((ref) {
  if (ref.watch(syncTargetProvider) == null) return null;
  // Built only once settings have loaded, because the cold-start staleness
  // check reads `lastSyncAt` the moment the scheduler starts. Watching
  // whether there is a value rather than the value itself keeps a settings
  // write from tearing the scheduler down and cancelling a pending run.
  if (!ref.watch(settingsProvider.select((AsyncValue<AppSettings> s) =>
      s.hasValue))) {
    return null;
  }

  final SyncScheduler scheduler = SyncScheduler(
    run: () => ref.read(syncStatusProvider.notifier).run(),
    lastSyncAt: () => ref.read(settingsProvider).value?.lastSyncAt,
  );
  ref.onDispose(scheduler.dispose);
  scheduler.start();
  return scheduler;
});

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
    // `applySyncMerge` has already reloaded, so only the stamp is left.
    if (result.ok) await _stampLastSync(coordinator.status.lastRunAt);
    return result;
  }

  /// Never awaited by a write path. Marking has already succeeded locally by
  /// the time this runs, and a failure is a line in Settings, not a modal.
  Future<SyncRunResult?> run({bool force = false}) async {
    final SyncCoordinator? coordinator = ref.read(syncCoordinatorProvider);
    if (coordinator == null) return null;
    if (state.state == SyncState.running) return null;
    // An unanswered merge question is not fixed by asking again, and every
    // automatic retry of it is a fetch of all nine kinds for an outcome that
    // is already known. The button still gets through, because pressing it is
    // how the user reaches the screen that answers it.
    if (!force && _last?.outcome == SyncRunOutcome.reviewNeeded) return null;

    await _forgetLedgerIfAccountChanged(coordinator.target.id);

    state = coordinator.status.running();
    final SyncRunResult result = await coordinator.run(force: force);
    _last = result;
    state = coordinator.status;
    unawaited(ref.read(analyticsProvider).syncRan(
          target: 'account',
          outcome: result.outcome.name,
        ));
    if (result.ok) {
      // Reload before stamping, not after: a pulled settings row is written
      // through the service, so `settingsProvider` still holds the pre-run
      // value and stamping from it would push the pulled settings straight
      // back out.
      if (result.pulled > 0) {
        await ref.read(actionsProvider).reloadAfterSync(
              target: coordinator.target.id,
              pulled: result.pulledKeys,
            );
      }
      await _stampLastSync(coordinator.status.lastRunAt);
    }
    return result;
  }

  /// The ledger keys on the target, and the target's id is the same string for
  /// every account, so nothing about signing out or deleting an account
  /// invalidates it on its own. Left alone, the next account inherits links
  /// saying its rows are already pushed, and a term's worth of history sits on
  /// a device the account has never been told about.
  ///
  /// A device that has never recorded which account it synced with keeps its
  /// ledger: the planner's `recreatesMissingRows` repairs it on the next run,
  /// and wiping here would put a device whose ledger is fine through a merge.
  Future<void> _forgetLedgerIfAccountChanged(String target) async {
    final User? user = ref.read(signedInUserProvider).value;
    final AppSettings? settings = ref.read(settingsProvider).value;
    if (user == null || settings == null) return;
    if (settings.syncedAccountId == user.uid) return;

    if (settings.syncedAccountId != null) {
      await ref.read(repositoryProvider).deleteRemoteLinksFor(target);
    }
    await ref
        .read(settingsProvider.notifier)
        .save(settings.copyWith(syncedAccountId: user.uid));
  }

  /// Kept in settings rather than only on the coordinator so the scheduler can
  /// still tell how old the last run is after the process has been killed.
  Future<void> _stampLastSync(DateTime? at) async {
    if (at == null) return;
    final AppSettings? current = ref.read(settingsProvider).value;
    if (current == null) return;
    await ref
        .read(settingsProvider.notifier)
        .save(current.copyWith(lastSyncAt: at));
  }
}
