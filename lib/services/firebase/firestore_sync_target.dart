import 'package:cloud_firestore/cloud_firestore.dart';

import '../../domain/sync/sync_target.dart';

/// The user's own account as a [SyncTarget], which is what makes attendance
/// the same on every device they sign in on.
///
/// Nothing here knows about Notion and nothing above here knows about
/// Firestore: a second integration is one more implementation of the same
/// interface.
class FirestoreSyncTarget implements SyncTarget {
  FirestoreSyncTarget({required this.uid, FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _firestore;

  @override
  String get id => 'firebase';

  /// Only ever holds what this app wrote, so a pull is the user's own second
  /// device rather than someone's hand edit, and asking them to review their
  /// own marks would make a fresh install unusable.
  @override
  bool get trustsPulls => true;

  static const Map<SyncKind, String> _collections = <SyncKind, String>{
    SyncKind.attendance: 'attendance',
    SyncKind.subject: 'subjects',
  };

  CollectionReference<Map<String, Object?>> _collection(SyncKind kind) =>
      _firestore.collection('users').doc(uid).collection(_collections[kind]!);

  @override
  Future<List<RemoteState>?> fetch(SyncKind kind) async {
    try {
      final QuerySnapshot<Map<String, Object?>> snapshot =
          await _collection(kind).get();
      return snapshot.docs
          .map((QueryDocumentSnapshot<Map<String, Object?>> doc) =>
              _stateFrom(kind, doc.id, doc.data()))
          .toList();
    } on FirebaseException {
      // Null says the far side could not be read, which turns the run into a
      // push-only one rather than one that concludes everything was deleted.
      return null;
    }
  }

  @override
  Future<SyncOutcome> create(SyncItem item) => _write(item, item.localKey);

  /// The document id is the sync key, so an update is the same call as a
  /// create and re-running a half-finished push cannot double anything.
  @override
  Future<SyncOutcome> update(SyncItem item, String remoteId) =>
      _write(item, remoteId);

  /// Writes a tombstone instead of removing the document. A device that has
  /// been offline has to be able to learn the row is gone; a missing document
  /// only tells it the row was never pushed.
  @override
  Future<SyncOutcome> archive(String remoteId) async {
    return _guard(() async {
      await _collection(SyncKind.attendance).doc(remoteId).set(
        <String, Object?>{
          'deletedAt': DateTime.now().millisecondsSinceEpoch,
        },
        SetOptions(merge: true),
      );
      return SyncOutcome.done(remoteId: remoteId, remoteHash: _deletedHash);
    });
  }

  Future<SyncOutcome> _write(SyncItem item, String remoteId) async {
    return _guard(() async {
      await _collection(item.kind).doc(remoteId).set(<String, Object?>{
        ...item.fields,
        'changedAt': item.changedAt?.millisecondsSinceEpoch,
        'deletedAt': null,
      });
      return SyncOutcome.done(remoteId: remoteId, remoteHash: item.hash);
    });
  }

  /// The hash is derived from what the document holds rather than stored
  /// alongside it, so it cannot drift from the content it describes.
  static RemoteState _stateFrom(
    SyncKind kind,
    String id,
    Map<String, Object?> data,
  ) {
    final bool deleted = data['deletedAt'] != null;
    final Map<String, Object?> fields = Map<String, Object?>.from(data)
      ..remove('changedAt')
      ..remove('deletedAt');
    final int? changedAt = data['changedAt'] as int?;

    return RemoteState(
      kind: kind,
      localKey: id,
      remoteId: id,
      hash: deleted
          ? _deletedHash
          : SyncItem(kind: kind, localKey: id, fields: fields).hash,
      fields: deleted ? const <String, Object?>{} : fields,
      editedAt: changedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(changedAt),
      deleted: deleted,
    );
  }

  /// One value for every tombstone, so a delete looks like a change exactly
  /// once and a device that has already applied it sees no further difference.
  static const String _deletedHash = 'deleted';

  Future<SyncOutcome> _guard(Future<SyncOutcome> Function() run) async {
    try {
      return await run();
    } on FirebaseException catch (error) {
      return SyncOutcome.failed(_reasonFor(error.code), message: error.code);
    } catch (error) {
      return SyncOutcome.failed(SyncFailure.unknown, message: '$error');
    }
  }

  static SyncFailure _reasonFor(String code) {
    switch (code) {
      case 'unavailable':
      case 'deadline-exceeded':
        return SyncFailure.offline;
      case 'permission-denied':
      case 'unauthenticated':
        return SyncFailure.auth;
      case 'resource-exhausted':
        return SyncFailure.rateLimited;
      case 'invalid-argument':
      case 'failed-precondition':
        return SyncFailure.rejected;
      default:
        return SyncFailure.unknown;
    }
  }
}
