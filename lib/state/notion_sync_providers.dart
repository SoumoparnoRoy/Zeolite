import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/class_category.dart';
import '../data/models/subject.dart';
import '../data/settings/app_settings.dart';
import '../domain/notion/notion_mapping.dart';
import '../domain/sync/sync_merge.dart';
import '../domain/sync/sync_plan.dart';
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
    courseName: (String uuid) => _subjectFor(ref, uuid)?.name,
    categoryName: (String uuid) {
      final int? id = _subjectFor(ref, uuid)?.categoryId;
      if (id == null) return null;
      for (final ClassCategory category
          in ref.read(timetableProvider).value?.categories ??
              const <ClassCategory>[]) {
        if (category.id == id) return category.name;
      }
      return null;
    },
  );
});

Subject? _subjectFor(Ref ref, String uuid) {
  for (final Subject subject
      in ref.read(timetableProvider).value?.subjects ?? const <Subject>[]) {
    if (subject.uuid == uuid) return subject;
  }
  return null;
}

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

  /// What a person still has to answer: rows edited in Notion since the app
  /// last saw them. Empty for a run that found none.
  List<SyncPull> get review => _last?.review ?? const <SyncPull>[];

  /// Settles the answers, then runs so a kept local row goes over the top.
  Future<SyncRunResult?> applyReview(Map<String, SyncSide> decisions) async {
    final SyncCoordinator? coordinator = ref.read(notionCoordinatorProvider);
    if (coordinator == null) return null;

    await coordinator.applyReview(review, decisions);
    // The rows that were taken have been written here, so the screens holding
    // them are stale until this lands.
    await ref.read(actionsProvider).reloadAfterSync();

    state = coordinator.status.running();
    final SyncRunResult result = await coordinator.runAfterReview();
    _last = result;
    state = coordinator.status;
    if (result.ok) await _stamp(coordinator.status.lastRunAt);
    return result;
  }

  /// Forgets what was pushed and runs again.
  ///
  /// Every page is recognised by its `Zeolite ID` and adopted rather than
  /// created a second time, so this rewrites the workspace's rows instead of
  /// duplicating them. It exists because a change to what the app writes — a
  /// column it did not fill before — leaves rows that are correct by their own
  /// hash and so would never be pushed again.
  Future<SyncRunResult?> resyncEverything() async {
    if (ref.read(notionCoordinatorProvider) == null) return null;
    await ref
        .read(repositoryProvider)
        .deleteRemoteLinksFor(NotionSyncTarget.targetId);
    return run(force: true);
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
