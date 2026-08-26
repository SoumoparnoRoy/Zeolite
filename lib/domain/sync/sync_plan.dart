import 'package:flutter/foundation.dart';

import 'sync_target.dart';

/// Why a row is being pushed.
enum SyncPushKind {
  /// Nothing on the far side yet.
  create,

  /// The far side already holds this row but the ledger has no link to it —
  /// after a reset, or a reinstall onto an existing database. Pushed rather
  /// than merged: the two hashes come from different sides and cannot be
  /// compared, so the app states what it has and the link is written from the
  /// result. Without this a re-link would create a second page for every mark.
  adopt,

  /// Changed here, untouched there.
  update,

  /// Changed in both places. It is still pushed — the app is where the user
  /// tapped — but it is listed so the overwrite is visible rather than silent.
  conflict,
}

/// What to do about a link whose local row has gone.
enum SyncDropKind {
  /// The app made the page, so it takes it away again — even if it has been
  /// edited since. Archiving is Notion's trash rather than a deletion, and the
  /// run reports the count, so a page removed under an edit is recoverable and
  /// not silent. Holding those back for a decision was weighed and turned
  /// down: it needs a queue nobody would clear.
  archive,

  /// Someone else's page. Forget the link and leave it standing.
  dropLink,
}

@immutable
class SyncPush {
  const SyncPush({
    required this.item,
    required this.kind,
    this.link,
    this.remote,
  });

  final SyncItem item;
  final SyncPushKind kind;

  /// Null for a create and for an adopt — neither has a link yet.
  final RemoteLink? link;

  /// Set on an adopt, where the page id comes from the fetch rather than the
  /// ledger.
  final RemoteState? remote;

  /// The page to write to, or null when one has to be made.
  String? get remoteId => link?.remoteId ?? remote?.remoteId;
}

/// A row that changed on the far side. Never written here: it goes through the
/// same preview the file import already uses, because a pull can restate
/// history and history is the thing the app exists to keep.
@immutable
class SyncPull {
  const SyncPull({required this.remote, this.link});

  final RemoteState remote;

  /// Null when the far side holds a row the app has never seen.
  final RemoteLink? link;
}

@immutable
class SyncDrop {
  const SyncDrop({required this.link, required this.kind});

  final RemoteLink link;
  final SyncDropKind kind;
}

/// One run's worth of work, derived by comparing local rows against the ledger.
///
/// Derived rather than queued: undo, backup restore and the importers all
/// replace rows wholesale, and an outbox written alongside each of those would
/// need bespoke reconstruction in four places. A diff cannot drift from the
/// database because there is nothing to drift.
@immutable
class SyncPlan {
  const SyncPlan({
    required this.pushes,
    required this.pulls,
    required this.drops,
    required this.unchanged,
  });

  final List<SyncPush> pushes;
  final List<SyncPull> pulls;
  final List<SyncDrop> drops;

  /// Rows that matched on both sides. Counted rather than listed so a run over
  /// a full term does not build a list it has no use for.
  final int unchanged;

  bool get isEmpty => pushes.isEmpty && pulls.isEmpty && drops.isEmpty;

  /// Pages this run would put in the target's trash. Reported after a run —
  /// removing someone's page is the one thing here that is not visible on the
  /// device afterwards, so it gets said out loud rather than counted silently.
  int get archiving =>
      drops.where((SyncDrop d) => d.kind == SyncDropKind.archive).length;

  /// Rows the app has changed and would write over.
  int get overwriting =>
      pushes.where((SyncPush p) => p.kind == SyncPushKind.conflict).length;

  /// [remote] null means the far side was not read this run — every link is
  /// then taken at its stored hash, which turns the run into a push-only one.
  static SyncPlan from({
    required List<SyncItem> local,
    required List<RemoteLink> links,
    List<RemoteState>? remote,
  }) {
    final Map<String, RemoteLink> linkByKey = <String, RemoteLink>{
      for (final RemoteLink link in links) link.localKey: link,
    };
    final Map<String, RemoteState> remoteByKey = <String, RemoteState>{
      for (final RemoteState state in remote ?? const <RemoteState>[])
        state.localKey: state,
    };

    final List<SyncPush> pushes = <SyncPush>[];
    final List<SyncPull> pulls = <SyncPull>[];
    final List<SyncDrop> drops = <SyncDrop>[];
    int unchanged = 0;

    for (final SyncItem item in local) {
      final RemoteLink? link = linkByKey[item.localKey];
      if (link == null) {
        final RemoteState? orphan = remoteByKey[item.localKey];
        pushes.add(
          SyncPush(
            item: item,
            kind: orphan == null ? SyncPushKind.create : SyncPushKind.adopt,
            remote: orphan,
          ),
        );
        continue;
      }

      final bool localChanged = item.hash != link.localHash;
      final bool remoteChanged = _remoteChanged(link, remoteByKey, remote);

      if (localChanged && remoteChanged) {
        pushes.add(
          SyncPush(item: item, kind: SyncPushKind.conflict, link: link),
        );
      } else if (localChanged) {
        pushes.add(SyncPush(item: item, kind: SyncPushKind.update, link: link));
      } else if (remoteChanged) {
        pulls.add(SyncPull(remote: remoteByKey[link.localKey]!, link: link));
      } else {
        unchanged++;
      }
    }

    final Set<String> localKeys = <String>{
      for (final SyncItem item in local) item.localKey,
    };

    for (final RemoteLink link in links) {
      if (localKeys.contains(link.localKey)) continue;
      drops.add(
        SyncDrop(
          link: link,
          kind: link.origin == SyncOrigin.app
              ? SyncDropKind.archive
              : SyncDropKind.dropLink,
        ),
      );
    }

    // Pages nobody here has ever linked. They are the import path, not a
    // conflict — a fresh install pointed at an existing database is all of
    // them at once.
    for (final RemoteState state in remote ?? const <RemoteState>[]) {
      if (linkByKey.containsKey(state.localKey)) continue;
      if (localKeys.contains(state.localKey)) continue;
      pulls.add(SyncPull(remote: state));
    }

    return SyncPlan(
      pushes: pushes,
      pulls: pulls,
      drops: drops,
      unchanged: unchanged,
    );
  }

  static bool _remoteChanged(
    RemoteLink link,
    Map<String, RemoteState> remoteByKey,
    List<RemoteState>? remote,
  ) {
    if (remote == null) return false;
    final RemoteState? state = remoteByKey[link.localKey];
    // A linked page that has stopped existing is not a change to pull; the
    // next push recreates it.
    if (state == null) return false;
    return state.hash != link.remoteHash;
  }
}
