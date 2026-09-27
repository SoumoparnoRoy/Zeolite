import '../../data/models/attendance_record.dart';
import 'sync_target.dart';

/// Marks whose start time changed here since the last run, found again on the
/// far side.
///
/// A moved mark shows up as a new key with no link beside a link whose key no
/// longer names anything, for the same subject and day. On a table a person
/// keeps that is the same class, and its page has to be updated in place:
/// archiving it would take their other columns with it, and leaving it would
/// file the class twice. Pairs go in start order, the way the marks were
/// matched. A store that files rows under the key itself needs none of this.
class SyncMoves {
  const SyncMoves({required this.moved, required this.forget});

  /// The links, re-keyed, with an empty local hash so the next plan pushes
  /// the new time and key into the page.
  final List<RemoteLink> moved;

  /// The keys those links were filed under.
  final List<String> forget;

  bool get isEmpty => moved.isEmpty;

  static const SyncMoves none =
      SyncMoves(moved: <RemoteLink>[], forget: <String>[]);

  /// Only links whose page [remote] still holds are followed; one removed on
  /// the far side is left to be dropped as it would have been.
  static SyncMoves find({
    required List<SyncItem> local,
    required List<RemoteLink> links,
    required List<RemoteState> remote,
  }) {
    final Set<String> localKeys = <String>{
      for (final SyncItem item in local) item.localKey,
    };
    final Set<String> linkedKeys = <String>{
      for (final RemoteLink link in links) link.localKey,
    };
    final Set<String> pages = <String>{
      for (final RemoteState state in remote)
        if (!state.deleted) state.remoteId,
    };

    final Map<String, List<RemoteLink>> gone = <String, List<RemoteLink>>{};
    for (final RemoteLink link in links) {
      if (localKeys.contains(link.localKey)) continue;
      if (!pages.contains(link.remoteId)) continue;
      final String? day = _dayOf(link.localKey);
      if (day == null) continue;
      gone.putIfAbsent(day, () => <RemoteLink>[]).add(link);
    }
    if (gone.isEmpty) return none;

    final Map<String, List<String>> fresh = <String, List<String>>{};
    for (final SyncItem item in local) {
      if (linkedKeys.contains(item.localKey)) continue;
      final String? day = _dayOf(item.localKey);
      if (day == null || !gone.containsKey(day)) continue;
      fresh.putIfAbsent(day, () => <String>[]).add(item.localKey);
    }

    final List<RemoteLink> moved = <RemoteLink>[];
    final List<String> forget = <String>[];
    for (final MapEntry<String, List<RemoteLink>> entry in gone.entries) {
      final List<String> keys = fresh[entry.key] ?? const <String>[];
      if (keys.isEmpty) continue;
      final List<RemoteLink> old = entry.value
        ..sort((RemoteLink a, RemoteLink b) => _byStart(a.localKey, b.localKey));
      keys.sort(_byStart);
      for (int i = 0; i < old.length && i < keys.length; i++) {
        forget.add(old[i].localKey);
        moved.add(
          RemoteLink(
            target: old[i].target,
            kind: old[i].kind,
            localKey: keys[i],
            remoteId: old[i].remoteId,
            localHash: '',
            remoteHash: old[i].remoteHash,
            origin: old[i].origin,
            syncedAt: old[i].syncedAt,
          ),
        );
      }
    }
    return SyncMoves(moved: moved, forget: forget);
  }

  /// [remote] with each page that a link holds under another key filed under
  /// that link's key. Until the push rewrites the page it still carries the
  /// old key, and read under it the page would look like a stranger to pull.
  static List<RemoteState> rekey(
    List<RemoteState> remote,
    List<RemoteLink> links,
  ) {
    final Map<String, String> keyOf = <String, String>{
      for (final RemoteLink link in links) link.remoteId: link.localKey,
    };
    return <RemoteState>[
      for (final RemoteState state in remote)
        switch (keyOf[state.remoteId]) {
          final String key when key != state.localKey => RemoteState(
              kind: state.kind,
              localKey: key,
              remoteId: state.remoteId,
              hash: state.hash,
              fields: state.fields,
              editedAt: state.editedAt,
              deleted: state.deleted,
            ),
          _ => state,
        },
    ];
  }

  /// `subject:date` of a mark's key, or null for one that is not a mark's.
  static String? _dayOf(String key) {
    final int cut = key.lastIndexOf(':');
    if (cut <= 0 || int.tryParse(key.substring(cut + 1)) == null) return null;
    return key.substring(0, cut);
  }

  static int _byStart(String a, String b) => AttendanceRecord.compareStarts(
        int.parse(a.substring(a.lastIndexOf(':') + 1)),
        int.parse(b.substring(b.lastIndexOf(':') + 1)),
      );
}
