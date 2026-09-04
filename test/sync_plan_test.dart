import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/domain/sync/sync_plan.dart';
import 'package:zeolite/domain/sync/sync_status.dart';
import 'package:zeolite/domain/sync/sync_target.dart';

import 'fake_sync_target.dart';

final DateTime _monday = DateTime(2026, 8, 3);

AttendanceRecord _mark({
  int subjectId = 1,
  AttendanceStatus status = AttendanceStatus.present,
  int weight = 1,
  String? note,
  int? tagId,
}) {
  return AttendanceRecord(
    subjectId: subjectId,
    date: _monday,
    startMinutes: 540,
    status: status,
    weight: weight,
    note: note,
    tagId: tagId,
  );
}

RemoteLink _link(
  SyncItem item, {
  String remoteId = 'page-1',
  String? localHash,
  String remoteHash = 'r1',
  SyncOrigin origin = SyncOrigin.app,
}) {
  return RemoteLink(
    target: 'fake',
    kind: item.kind,
    localKey: item.localKey,
    remoteId: remoteId,
    localHash: localHash ?? item.hash,
    remoteHash: remoteHash,
    origin: origin,
  );
}

RemoteState _state(
  SyncItem item, {
  String remoteId = 'page-1',
  String hash = 'r1',
}) {
  return RemoteState(
    kind: item.kind,
    localKey: item.localKey,
    remoteId: remoteId,
    hash: hash,
  );
}

const String _subjectUuid = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';

void main() {
  final SyncItem present = SyncItem.attendance(_mark(), _subjectUuid);
  final SyncItem absent =
      SyncItem.attendance(_mark(status: AttendanceStatus.absent), _subjectUuid);

  group('the fingerprint', () {
    test('moves when a target could see the change', () {
      expect(present.hash, isNot(absent.hash));
      expect(
        SyncItem.attendance(_mark(weight: 2), _subjectUuid).hash,
        isNot(present.hash),
      );
    });

    test('holds still for a tag, which is a local label', () {
      expect(SyncItem.attendance(_mark(tagId: 7), _subjectUuid).hash, present.hash);
    });

    test('does not depend on the order fields were built in', () {
      const SyncItem one = SyncItem(
        kind: SyncKind.attendance,
        localKey: '1:20260803:540',
        fields: <String, Object?>{'status': 'present', 'weight': 1},
      );
      const SyncItem other = SyncItem(
        kind: SyncKind.attendance,
        localKey: '1:20260803:540',
        fields: <String, Object?>{'weight': 1, 'status': 'present'},
      );
      expect(one.hash, other.hash);
    });
  });

  group('the planner', () {
    test('an unlinked mark is a create', () {
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[present],
        links: const <RemoteLink>[],
      );

      expect(plan.pushes.single.kind, SyncPushKind.create);
      expect(plan.pushes.single.remoteId, isNull);
      expect(plan.unchanged, 0);
    });

    test('a matching link is no work at all', () {
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[present],
        links: <RemoteLink>[_link(present)],
        remote: <RemoteState>[_state(present)],
      );

      expect(plan.isEmpty, isTrue);
      expect(plan.unchanged, 1);
    });

    test('re-marking the same class is an update to the same page', () {
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[absent],
        links: <RemoteLink>[_link(present, remoteId: 'page-9')],
        remote: <RemoteState>[_state(present, remoteId: 'page-9')],
      );

      expect(plan.pushes.single.kind, SyncPushKind.update);
      expect(plan.pushes.single.remoteId, 'page-9');
    });

    test('a mark that is gone archives the page the app made', () {
      final SyncPlan plan = SyncPlan.from(
        local: const <SyncItem>[],
        links: <RemoteLink>[_link(present)],
        remote: <RemoteState>[_state(present)],
      );

      expect(plan.drops.single.kind, SyncDropKind.archive);
    });

    test('a page the app did not make only loses its link', () {
      final SyncPlan plan = SyncPlan.from(
        local: const <SyncItem>[],
        links: <RemoteLink>[_link(present, origin: SyncOrigin.remote)],
        remote: <RemoteState>[_state(present)],
      );

      expect(plan.drops.single.kind, SyncDropKind.dropLink);
    });

    test('a page edited since is still archived, and counted', () {
      final SyncPlan plan = SyncPlan.from(
        local: const <SyncItem>[],
        links: <RemoteLink>[_link(present)],
        remote: <RemoteState>[_state(present, hash: 'r2')],
      );

      expect(plan.drops.single.kind, SyncDropKind.archive);
      expect(plan.archiving, 1);
    });

    test('a store the app owns archives its own pulled rows too', () {
      final SyncPlan plan = SyncPlan.from(
        local: const <SyncItem>[],
        links: <RemoteLink>[_link(present, origin: SyncOrigin.remote)],
        remote: <RemoteState>[_state(present)],
        ownsRows: true,
      );

      // Renaming a name-keyed row drops its old key, and left standing the
      // next device pulls that name back alongside the new one.
      expect(plan.drops.single.kind, SyncDropKind.archive);
    });

    test('forgetting a link is not counted as archiving', () {
      final SyncPlan plan = SyncPlan.from(
        local: const <SyncItem>[],
        links: <RemoteLink>[_link(present, origin: SyncOrigin.remote)],
        remote: <RemoteState>[_state(present)],
      );

      expect(plan.archiving, 0);
    });

    test('a page nobody here has linked is offered as an import', () {
      final SyncPlan plan = SyncPlan.from(
        local: const <SyncItem>[],
        links: const <RemoteLink>[],
        remote: <RemoteState>[_state(present, remoteId: 'page-4')],
      );

      expect(plan.pulls.single.link, isNull);
      expect(plan.pulls.single.remote.remoteId, 'page-4');
      expect(plan.pushes, isEmpty);
    });

    test('a mark whose page exists but whose link is gone is adopted', () {
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[present],
        links: const <RemoteLink>[],
        remote: <RemoteState>[_state(present, remoteId: 'page-4')],
      );

      expect(plan.pushes.single.kind, SyncPushKind.adopt);
      expect(plan.pushes.single.remoteId, 'page-4');
      expect(plan.pulls, isEmpty);
    });

    test('an unread far side pushes without inventing pulls', () {
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[absent],
        links: <RemoteLink>[_link(present)],
      );

      expect(plan.pushes.single.kind, SyncPushKind.update);
      expect(plan.pulls, isEmpty);
    });

    test('a link whose page has vanished is left to the next push', () {
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[present],
        links: <RemoteLink>[_link(present)],
        remote: const <RemoteState>[],
      );

      expect(plan.isEmpty, isTrue);
      expect(plan.unchanged, 1);
    });
  });

  group('the conflict matrix', () {
    test('changed there only is pulled, never written over', () {
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[present],
        links: <RemoteLink>[_link(present)],
        remote: <RemoteState>[_state(present, hash: 'r2')],
      );

      expect(plan.pushes, isEmpty);
      expect(plan.pulls.single.link, isNotNull);
    });

    test('changed in both places, the app wins and says so', () {
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[absent],
        links: <RemoteLink>[_link(present)],
        remote: <RemoteState>[_state(present, hash: 'r2')],
      );

      expect(plan.pushes.single.kind, SyncPushKind.conflict);
      expect(plan.pulls, isEmpty);
      expect(plan.overwriting, 1);
    });
  });

  group('backoff', () {
    const SyncBackoff backoff = SyncBackoff();

    test('doubles and then stops at the cap', () {
      expect(backoff.delayFor(0), Duration.zero);
      expect(backoff.delayFor(1), const Duration(seconds: 30));
      expect(backoff.delayFor(2), const Duration(minutes: 1));
      expect(backoff.delayFor(4), const Duration(minutes: 4));
      expect(backoff.delayFor(7), const Duration(minutes: 30));
      expect(backoff.delayFor(40), const Duration(minutes: 30));
    });

    test('a run offline is a state of its own, not an error', () {
      final SyncStatus status =
          const SyncStatus().failed(SyncFailure.offline);

      expect(status.state, SyncState.offline);
      expect(backoff.delayFor(status.failures), const Duration(seconds: 30));
    });

    test('a good run clears the count', () {
      final SyncStatus status = const SyncStatus()
          .failed(SyncFailure.rateLimited)
          .failed(SyncFailure.rateLimited)
          .succeeded(_monday);

      expect(status.failures, 0);
      expect(status.state, SyncState.idle);
      expect(status.lastRunAt, _monday);
    });
  });

  group('the ledger', () {
    test('undo does not roll it back', () {
      expect(
        ZeoliteRepository.snapshotTables,
        isNot(contains('remote_links')),
      );
    });

    test('survives the round trip through SQLite', () {
      final RemoteLink link = _link(present, origin: SyncOrigin.remote);
      final RemoteLink back = RemoteLink.fromMap(link.toMap());

      expect(back.localKey, link.localKey);
      expect(back.remoteId, link.remoteId);
      expect(back.localHash, link.localHash);
      expect(back.remoteHash, link.remoteHash);
      expect(back.origin, SyncOrigin.remote);
      expect(back.kind, SyncKind.attendance);
    });
  });

  group('a target', () {
    test('reports what it wrote, and the plan then reads as done', () async {
      final FakeSyncTarget target = FakeSyncTarget();
      final SyncPlan plan = SyncPlan.from(
        local: <SyncItem>[present],
        links: const <RemoteLink>[],
        remote: const <RemoteState>[],
      );

      final SyncOutcome outcome = await target.create(plan.pushes.single.item);
      expect(outcome.ok, isTrue);

      final RemoteLink written = RemoteLink(
        target: target.id,
        kind: SyncKind.attendance,
        localKey: present.localKey,
        remoteId: outcome.remoteId!,
        localHash: present.hash,
        remoteHash: outcome.remoteHash!,
        origin: SyncOrigin.app,
      );
      final SyncPlan after = SyncPlan.from(
        local: <SyncItem>[present],
        links: <RemoteLink>[written],
        remote: <RemoteState>[
          _state(
            present,
            remoteId: outcome.remoteId!,
            hash: outcome.remoteHash!,
          ),
        ],
      );

      expect(after.isEmpty, isTrue);
    });

    test('a failure carries a reason and writes nothing', () async {
      final FakeSyncTarget target = FakeSyncTarget()
        ..failNext = SyncFailure.offline;

      final SyncOutcome outcome = await target.create(present);

      expect(outcome.ok, isFalse);
      expect(outcome.failure, SyncFailure.offline);
      expect(target.pages, isEmpty);
    });

    test('a far side it could not read is null, not empty', () async {
      final FakeSyncTarget target = FakeSyncTarget()..remote = null;

      expect(await target.fetch(SyncKind.attendance), isNull);
    });
  });
}
