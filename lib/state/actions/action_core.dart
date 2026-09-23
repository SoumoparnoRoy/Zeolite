import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/zeolite_repository.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/schedule_engine.dart';
import '../../domain/sync/sync_target.dart';
import '../../services/analytics_service.dart';
import '../notion_sync_providers.dart';
import '../providers.dart';
import '../sync_providers.dart';
import '../undo.dart';

/// The plumbing every action shares: the database, the one refresh that
/// rebuilds the engine, the day lists and the stats, and the Undo store an
/// action arms after it has written.
class ActionCore {
  ActionCore(this.ref);

  final Ref ref;

  ZeoliteRepository get repo => ref.read(repositoryProvider);

  Analytics get analytics => ref.read(analyticsProvider);

  final UndoStore _undo = UndoStore();

  /// Arms an Undo offer against the database as it stood before an action.
  ///
  /// [settings] too when the action changed one: the snapshot holds only the
  /// database, and an import that switched a setting would otherwise leave it
  /// switched after its marks were gone.
  int arm(DatabaseSnapshot before, {AppSettings? settings}) {
    final int token = _undo.arm(before);
    _settingsUndo = settings == null ? null : (token, settings);
    return token;
  }

  (int, AppSettings)? _settingsUndo;

  Future<DatabaseSnapshot> snapshot() => repo.snapshot();

  Future<void> refresh() async {
    // Every mutation comes through here, so this is where the pending undo is
    // dropped: restoring it would throw away whatever the user did since.
    _dropUndo();
    await _reload();
    // Every scheduler, or a change would reach one target and quietly never
    // reach the other.
    ref.read(syncSchedulerProvider)?.onLocalChange();
    ref.read(notionSchedulerProvider)?.onLocalChange();
  }

  /// A mark made from a home-screen widget is written by a second isolate, so
  /// nothing in the running app knows the rows moved. Called on resume when the
  /// widget reports it wrote something.
  Future<void> reloadAfterWidgetMark() => refresh();

  /// Split out of [refresh] because a pull needs all of this without
  /// announcing a local change, which would schedule the rows it just brought
  /// down straight back up.
  Future<void> _reload() async {
    ref.invalidate(timetableProvider);
    await ref.read(timetableProvider.future);
    await _syncNotifications();
  }

  /// A run writes straight through the repository and the settings service, so
  /// without this nothing reading either provider knows the database moved.
  ///
  /// A caller that can name what it pulled leaves a standing Undo offer alone;
  /// one that cannot passes no [target] and the offer goes, since a restore
  /// would then delete rows nothing knows how to bring back.
  Future<void> reloadAfterSync({
    String? target,
    Map<SyncKind, List<String>> pulled = const <SyncKind, List<String>>{},
  }) async {
    if (target == null) {
      _dropUndo();
    } else {
      _recordPull(target, pulled);
    }
    ref.invalidate(settingsProvider);
    await ref.read(settingsProvider.future);
    await _reload();
  }

  /// Alarms already in the system keep the mode they were scheduled with, so
  /// granting exact alarms only takes effect once they are laid down again.
  Future<void> refreshNotifications() => _syncNotifications();

  Future<void> _syncNotifications() async {
    final AppSettings? settings = ref.read(settingsProvider).value;
    final ScheduleEngine? engine = ref.read(scheduleEngineProvider);
    if (settings == null || engine == null) return;
    await ref.read(notificationsProvider).rescheduleAll(
          settings: settings,
          upcoming: engine.upcomingSessions(),
          stats: ref.read(statsProvider),
        );
  }

  /// Undoing a merge has to take the ledger with it. `remote_links` is outside
  /// the snapshot by design, so a plain restore would put the local rows back
  /// while leaving links that say the account holds them — and the next run
  /// would read those rows as deleted here and archive the account's copies.
  /// Forgetting the ledger instead returns the pair to "not yet reconciled",
  /// which is the state the merge screen is for.
  int? _mergeUndoToken;
  String? _mergeUndoTarget;

  // undo ---------------------------------------------------------------------

  int? get pendingUndoToken => _undo.pendingToken;

  /// Rows a sync brought down while the pending snapshot was standing, by
  /// target and kind.
  ///
  /// A background run is not the user, so it must not kill an offer raised
  /// seconds earlier by a tap. Keeping the offer is only safe if a restore can
  /// account for what arrived meanwhile: it deletes those rows again, so their
  /// ledger entries go with them and the next run pulls them back, rather than
  /// reading them as deleted here and archiving the far side's copies.
  final Map<String, Map<SyncKind, List<String>>> _pulledSinceUndo =
      <String, Map<SyncKind, List<String>>>{};

  void _dropUndo() {
    _undo.drop();
    _mergeUndoToken = null;
    _settingsUndo = null;
    _pulledSinceUndo.clear();
  }

  void _recordPull(String target, Map<SyncKind, List<String>> pulled) {
    if (_undo.pendingToken == null) return;
    final Map<SyncKind, List<String>> forTarget =
        _pulledSinceUndo.putIfAbsent(target, () => <SyncKind, List<String>>{});
    pulled.forEach((SyncKind kind, List<String> keys) {
      forTarget.putIfAbsent(kind, () => <String>[]).addAll(keys);
    });
  }

  /// Puts the database back as it stood before the action [token] belongs to.
  /// False once that offer has been overtaken, which is what stops a snackbar
  /// still on screen from undoing something it did not name.
  Future<bool> undo(int token) async {
    final DatabaseSnapshot? snapshot = _undo.take(token);
    if (snapshot == null) return false;
    final (int, AppSettings)? settings = _settingsUndo;
    await repo.restore(snapshot);
    if (settings != null && settings.$1 == token) {
      await ref.read(settingsProvider.notifier).save(settings.$2);
    }
    if (token == _mergeUndoToken && _mergeUndoTarget != null) {
      await repo.deleteRemoteLinksFor(_mergeUndoTarget!);
    }
    for (final MapEntry<String, Map<SyncKind, List<String>>> target
        in _pulledSinceUndo.entries) {
      for (final MapEntry<SyncKind, List<String>> kind
          in target.value.entries) {
        await repo.deleteRemoteLinks(target.key, kind.key, kind.value);
      }
    }
    await refresh();
    unawaited(analytics.undoUsed());
    return true;
  }

  /// Awaited for the same reason as [reloadAfterSync], and it matters more
  /// here: a restore can move the semester dates the reminders hang off.
  Future<void> reloadAfterImport() async {
    ref.invalidate(settingsProvider);
    await ref.read(settingsProvider.future);
    await refresh();
    unawaited(analytics.backupRestored());
  }

  /// Undoing a merge has to forget that target's ledger too, so the token
  /// the merge was armed under is kept apart from any other offer.
  int armMerge(DatabaseSnapshot before, String target) {
    _mergeUndoToken = arm(before);
    _mergeUndoTarget = target;
    return _mergeUndoToken!;
  }
}
