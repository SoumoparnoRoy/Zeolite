import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/firebase/firestore_sync_target.dart';

const String _uid = 'test-user';
const String _subject = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';

SyncItem _mark({String status = 'present', int weight = 1}) => SyncItem(
      kind: SyncKind.attendance,
      localKey: '$_subject:20260828:540',
      fields: <String, Object?>{
        'status': status,
        'weight': weight,
        'note': null,
      },
      changedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

void main() {
  late FakeFirebaseFirestore firestore;
  late FirestoreSyncTarget target;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    target = FirestoreSyncTarget(uid: _uid, firestore: firestore);
  });

  test('a mark comes back with the hash it went up with', () async {
    final SyncItem item = _mark();
    final SyncOutcome outcome = await target.create(item);

    expect(outcome.ok, isTrue);
    expect(outcome.remoteId, item.localKey);

    final List<RemoteState>? states =
        await target.fetch(SyncKind.attendance);
    final RemoteState state = states!.single;
    expect(state.localKey, item.localKey);
    expect(state.deleted, isFalse);
    // Derived from the document rather than stored, so a hash and the content
    // it describes cannot disagree.
    expect(state.hash, item.hash);
  });

  test('pushing the same key twice leaves one row, not two', () async {
    await target.create(_mark());
    await target.update(_mark(status: 'absent'), _mark().localKey);

    final List<RemoteState> states =
        (await target.fetch(SyncKind.attendance))!;
    expect(states, hasLength(1));
    expect(states.single.hash, _mark(status: 'absent').hash);
  });

  test('archiving leaves a tombstone a stale device can still see', () async {
    final SyncItem item = _mark();
    await target.create(item);
    final SyncOutcome outcome = await target.archive(SyncKind.attendance, item.localKey);
    expect(outcome.ok, isTrue);

    final List<RemoteState> states =
        (await target.fetch(SyncKind.attendance))!;
    // Still present, and flagged. A removed document would read as "never
    // pushed", and the next run would put the deleted mark straight back.
    expect(states, hasLength(1));
    expect(states.single.deleted, isTrue);
    expect(states.single.hash, isNot(item.hash));
  });

  test('a re-push after a delete clears the tombstone', () async {
    final SyncItem item = _mark();
    await target.create(item);
    await target.archive(SyncKind.attendance, item.localKey);
    await target.update(item, item.localKey);

    final RemoteState state =
        (await target.fetch(SyncKind.attendance))!.single;
    expect(state.deleted, isFalse);
    expect(state.hash, item.hash);
  });

  test('subjects and attendance do not share a collection', () async {
    await target.create(_mark());
    await target.create(SyncItem(
      kind: SyncKind.subject,
      localKey: _subject,
      fields: const <String, Object?>{'name': 'Generic Course'},
    ));

    expect((await target.fetch(SyncKind.attendance))!, hasLength(1));
    expect((await target.fetch(SyncKind.subject))!, hasLength(1));
  });

  test('everything is written under the signed-in user and nowhere else',
      () async {
    await target.create(_mark());

    final QuerySnapshot<Map<String, Object?>> mine = await firestore
        .collection('users')
        .doc(_uid)
        .collection('attendance')
        .get();
    expect(mine.docs, hasLength(1));

    final QuerySnapshot<Map<String, Object?>> someoneElse = await firestore
        .collection('users')
        .doc('another-user')
        .collection('attendance')
        .get();
    expect(someoneElse.docs, isEmpty);
  });
}
