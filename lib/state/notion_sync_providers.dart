import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/subject.dart';
import '../data/settings/app_settings.dart';
import '../domain/notion/notion_mapping.dart';
import '../domain/sync/sync_status.dart';
import '../domain/sync/sync_target.dart';
import '../services/notion/notion_sync_target.dart';
import '../services/sync/sync_coordinator.dart';
import '../services/sync/sync_scheduler.dart';
import 'notion_providers.dart';
import 'providers.dart';

/// Notion as somewhere to mirror to, or null until it can be written to.
///
/// Both halves are required: a connection says the app may write, and a
/// mapping says where. Without either there is nothing to file a mark under.
final notionSyncTargetProvider = Provider<SyncTarget?>((ref) {
  if (ref.watch(notionConnectionProvider).value == null) return null;
  final NotionMapping? mapping = ref.watch(notionMappingProvider).value;
  if (mapping == null || !mapping.isComplete) return null;

  return NotionSyncTarget(
    client: ref.watch(notionClientProvider),
    mapping: mapping,
    // Read per call rather than captured, so renaming a course reaches the
    // next run instead of the next restart.
    courseName: (String uuid) {
      for (final Subject subject
          in ref.read(timetableProvider).value?.subjects ??
              const <Subject>[]) {
        if (subject.uuid == uuid) return subject.name;
      }
      return null;
    },
  );
});

/// Deliberately a second coordinator rather than a second target on the first
/// one: backoff, status and the last result are per-target, and a workspace
/// that is refusing writes must not hold back the account's sync.
final notionCoordinatorProvider = Provider<SyncCoordinator?>((ref) {
  final SyncTarget? target = ref.watch(notionSyncTargetProvider);
  if (target == null) return null;
  return SyncCoordinator(
    repository: ref.watch(repositoryProvider),
    settings: ref.watch(settingsServiceProvider),
    target: target,
  );
});

final notionSyncStatusProvider =
    NotifierProvider<NotionSyncController, SyncStatus>(
  NotionSyncController.new,
);

/// The automatic triggers, alive only while Notion can be written to and the
/// user has left them on.
final notionSchedulerProvider = Provider<SyncScheduler?>((ref) {
  if (ref.watch(notionSyncTargetProvider) == null) return null;
  final AppSettings? settings = ref.watch(settingsProvider).value;
  if (settings == null || !settings.notionAutoSync) return null;

  final SyncScheduler scheduler = SyncScheduler(
    run: () => ref.read(notionSyncStatusProvider.notifier).run(),
    lastSyncAt: () => ref.read(settingsProvider).value?.lastNotionSyncAt,
  );
  ref.onDispose(scheduler.dispose);
  scheduler.start();
  return scheduler;
});

/// What the Notion section reads, and what its button calls.
class NotionSyncController extends Notifier<SyncStatus> {
  SyncRunResult? _last;
  SyncRunResult? get lastResult => _last;

  @override
  SyncStatus build() {
    // Disconnecting has to clear this, or Settings goes on reporting a run
    // against a workspace the app can no longer reach.
    ref.watch(notionSyncTargetProvider);
    return const SyncStatus();
  }

  /// Never awaited by a write path — marking has already succeeded locally by
  /// the time this runs, and a failure is a line in Settings, not a modal.
  Future<SyncRunResult?> run({bool force = false}) async {
    final SyncCoordinator? coordinator = ref.read(notionCoordinatorProvider);
    if (coordinator == null) return null;
    if (state.state == SyncState.running) return null;

    state = coordinator.status.running();
    final SyncRunResult result = await coordinator.run(force: force);
    _last = result;
    state = coordinator.status;
    if (result.ok) await _stamp(coordinator.status.lastRunAt);
    return result;
  }

  /// Its own stamp, so staleness is judged per target — see
  /// [AppSettings.lastNotionSyncAt].
  Future<void> _stamp(DateTime? at) async {
    if (at == null) return;
    final AppSettings? current = ref.read(settingsProvider).value;
    if (current == null) return;
    await ref
        .read(settingsProvider.notifier)
        .save(current.copyWith(lastNotionSyncAt: at));
  }
}
