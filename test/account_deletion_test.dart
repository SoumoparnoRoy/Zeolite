import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/firebase/firestore_sync_target.dart';

/// Deletion once cleared two of the nine collections sync writes, leaving a
/// user's whole timetable behind an account they had deleted.
const String _uid = 'test-user';
const String _subject = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';

SyncItem _itemOf(SyncKind kind) => switch (kind) {
      SyncKind.attendance => SyncItem(
          kind: kind,
          localKey: '$_subject:20260828:540',
          fields: const <String, Object?>{'status': 'present', 'weight': 1},
        ),
      SyncKind.settings => SyncItem(
          kind: kind,
          localKey: SyncItem.settingsKey,
          fields: const <String, Object?>{'targetPercent': 75.0},
        ),
      SyncKind.holiday => SyncItem(
          kind: kind,
          localKey: '${Dates.keyOf(DateTime(2026, 10, 2))}',
          fields: const <String, Object?>{'name': 'A day off'},
        ),
      _ => SyncItem(
          kind: kind,
          localKey: '$_subject-${kind.name}',
          fields: <String, Object?>{'name': 'Row for ${kind.name}'},
        ),
    };

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() => firestore = FakeFirebaseFirestore());

  Future<int> documentsUnderUser() async {
    int total = 0;
    for (final String name in FirestoreSyncTarget.collectionNames) {
      final QuerySnapshot<Map<String, Object?>> page = await firestore
          .collection('users')
          .doc(_uid)
          .collection(name)
          .get();
      total += page.docs.length;
    }
    return total;
  }

  test('deletion clears a document from every collection sync writes', () async {
    final FirestoreSyncTarget target =
        FirestoreSyncTarget(uid: _uid, firestore: firestore);
    for (final SyncKind kind in SyncKind.values) {
      await target.create(_itemOf(kind));
    }
    // A set-up that wrote nothing would pass the assertion below for free.
    expect(await documentsUnderUser(), SyncKind.values.length);

    final int removed = await FirestoreSyncTarget.deleteEverythingFor(
      firestore: firestore,
      uid: _uid,
    );

    // The sweep's own count, not the store: see [deleteEverythingFor].
    expect(removed, SyncKind.values.length);
  });

  test('deleting an account leaves another account untouched', () async {
    await FirestoreSyncTarget(uid: 'someone-else', firestore: firestore)
        .create(_itemOf(SyncKind.attendance));

    await FirestoreSyncTarget.deleteEverythingFor(
      firestore: firestore,
      uid: _uid,
    );

    final QuerySnapshot<Map<String, Object?>> theirs = await firestore
        .collection('users')
        .doc('someone-else')
        .collection('attendance')
        .get();
    expect(theirs.docs, hasLength(1));
  });
}
