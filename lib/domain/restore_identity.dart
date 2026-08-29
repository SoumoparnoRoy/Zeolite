import 'package:flutter/foundation.dart';

/// A row reduced to what identity matching needs: the natural key it can be
/// recognised by, and the identity it already carries. A null [uuid] is a row
/// out of a backup written before the schema that added one.
@immutable
class RowIdentity {
  const RowIdentity({required this.key, this.uuid});

  final String? key;
  final String? uuid;
}

/// Pairs rows carrying no shared identity onto rows that do, returning an index
/// into [unknown] against the uuid it should adopt.
///
/// A key worn twice identifies neither of the rows wearing it, so a match needs
/// the key to name exactly one row on *each* side. Folding two real rows
/// together would merge their attendance with nothing left to unpick them by,
/// and restoring as new is the loud failure rather than the silent one.
Map<int, String> matchByKey({
  required List<RowIdentity> unknown,
  required List<RowIdentity> known,
}) {
  final Map<String, String> byKey = _unambiguous(known);
  if (byKey.isEmpty) return const <int, String>{};

  final Map<String, int> claimants = <String, int>{};
  for (int i = 0; i < unknown.length; i++) {
    final String? key = _clean(unknown[i].key);
    if (key == null) continue;
    // A second claimant disqualifies the key outright, so -1 rather than
    // leaving the first one holding a match it cannot be shown to deserve.
    claimants[key] = claimants.containsKey(key) ? -1 : i;
  }

  final Map<int, String> matches = <int, String>{};
  claimants.forEach((String key, int index) {
    if (index < 0) return;
    final String? uuid = byKey[key];
    if (uuid != null) matches[index] = uuid;
  });
  return matches;
}

/// The code, folded. It is free text on the way in and not unique in the
/// schema, so ambiguity is left to [matchByKey] to throw out.
String? subjectKey(String? code) => _clean(code)?.toUpperCase();

/// A slot is recognised by the triple attendance is filed under, which the
/// weekly form already refuses to let two classes of one subject share. End
/// times and dates are left out deliberately: they are the fields most likely
/// to have been corrected since, and would only make a match fail.
String? slotKey(String? subjectUuid, int weekday, int startMinutes) =>
    subjectUuid == null ? null : '$subjectUuid|$weekday|$startMinutes';

/// Its date rather than a weekday, kept unique by `ClassClash.forOneOff`.
String? extraKey(String? subjectUuid, int dateKey, int startMinutes) =>
    subjectUuid == null ? null : '$subjectUuid|$dateKey|$startMinutes';

Map<String, String> _unambiguous(List<RowIdentity> rows) {
  final Map<String, String?> found = <String, String?>{};
  for (final RowIdentity row in rows) {
    final String? key = _clean(row.key);
    final String? uuid = row.uuid;
    if (key == null || uuid == null) continue;
    found[key] = found.containsKey(key) ? null : uuid;
  }
  return <String, String>{
    for (final MapEntry<String, String?> entry in found.entries)
      if (entry.value != null) entry.key: entry.value!,
  };
}

String? _clean(String? key) {
  final String trimmed = (key ?? '').trim();
  return trimmed.isEmpty ? null : trimmed;
}
