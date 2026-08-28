import 'package:flutter/foundation.dart';

import 'sync_target.dart';

/// Which copy of a row to keep.
enum SyncSide { here, there }

/// One key, with whichever sides hold it.
@immutable
class SyncMergeRow {
  const SyncMergeRow({
    required this.kind,
    required this.localKey,
    this.local,
    this.remote,
  });

  final SyncKind kind;
  final String localKey;
  final SyncItem? local;
  final RemoteState? remote;

  /// What the row says, taken from whichever side holds it. The screen reads
  /// this to name a row; on a differing row the two sides disagree and it is
  /// the local copy that is shown, since that is the one already on screen
  /// everywhere else in the app.
  Map<String, Object?> get fields =>
      local?.fields ?? remote?.fields ?? const <String, Object?>{};

  /// The side edited more recently, which is what a differing row defaults to.
  ///
  /// An undated remote row loses: it cannot be shown to be newer, and this
  /// device at least knows the user was here. A tombstone has no edit time of
  /// its own worth trusting either, so accepting a deletion is always a
  /// deliberate flip rather than something that happens by default.
  SyncSide get newer {
    final RemoteState? state = remote;
    if (state == null || state.deleted) return SyncSide.here;
    final DateTime? theirs = state.editedAt;
    if (theirs == null) return SyncSide.here;
    final DateTime? mine = local?.changedAt;
    if (mine == null) return SyncSide.there;
    return theirs.isAfter(mine) ? SyncSide.there : SyncSide.here;
  }
}

/// The two sides of a first sign-in, sorted into what needs asking and what
/// does not.
///
/// Built without a ledger on purpose: this exists precisely for the run where
/// there is no ledger to reconcile the sides with, so every row is judged on
/// its content alone.
@immutable
class SyncMergePlan {
  const SyncMergePlan({
    required this.onlyHere,
    required this.onlyThere,
    required this.differing,
    required this.agreed,
  });

  /// Rows this device holds and the account does not. They go up; there is
  /// nothing to decide, so they are counted rather than listed.
  final List<SyncMergeRow> onlyHere;

  /// Rows the account holds and this device does not. They come down, for the
  /// same reason.
  final List<SyncMergeRow> onlyThere;

  /// Rows both sides hold and disagree about. The only thing a person has to
  /// answer.
  final List<SyncMergeRow> differing;

  /// Rows both sides already hold identically. Nothing happens to them, but
  /// the count is worth showing — it is what tells someone the two sides are
  /// mostly the same history rather than two unrelated ones.
  final List<SyncMergeRow> agreed;

  bool get isEmpty =>
      onlyHere.isEmpty && onlyThere.isEmpty && differing.isEmpty;

  /// Every differing row at its default, which is what the screen opens on.
  Map<String, SyncSide> get defaults => <String, SyncSide>{
        for (final SyncMergeRow row in differing) row.localKey: row.newer,
      };

  static SyncMergePlan from({
    required List<SyncItem> local,
    required List<RemoteState> remote,
  }) {
    final Map<String, SyncItem> localByKey = <String, SyncItem>{
      for (final SyncItem item in local) item.localKey: item,
    };

    final List<SyncMergeRow> onlyHere = <SyncMergeRow>[];
    final List<SyncMergeRow> onlyThere = <SyncMergeRow>[];
    final List<SyncMergeRow> differing = <SyncMergeRow>[];
    final List<SyncMergeRow> agreed = <SyncMergeRow>[];
    final Set<String> seen = <String>{};

    for (final RemoteState state in remote) {
      seen.add(state.localKey);
      final SyncItem? mine = localByKey[state.localKey];

      if (mine == null) {
        // A tombstone for a row this device never had is not something to
        // bring down or to ask about — there is nothing for it to delete.
        if (!state.deleted) {
          onlyThere.add(
            SyncMergeRow(
              kind: state.kind,
              localKey: state.localKey,
              remote: state,
            ),
          );
        }
        continue;
      }

      final SyncMergeRow row = SyncMergeRow(
        kind: state.kind,
        localKey: state.localKey,
        local: mine,
        remote: state,
      );
      // A tombstone against a row still held here is a real disagreement: one
      // device deleted it and the other did not.
      if (state.deleted || mine.hash != state.hash) {
        differing.add(row);
      } else {
        agreed.add(row);
      }
    }

    for (final SyncItem item in local) {
      if (seen.contains(item.localKey)) continue;
      onlyHere.add(
        SyncMergeRow(
          kind: item.kind,
          localKey: item.localKey,
          local: item,
        ),
      );
    }

    return SyncMergePlan(
      onlyHere: onlyHere,
      onlyThere: onlyThere,
      differing: differing,
      agreed: agreed,
    );
  }
}
