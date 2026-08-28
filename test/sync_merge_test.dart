import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/sync/sync_merge.dart';
import 'package:zeolite/domain/sync/sync_target.dart';

const String _uuid = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';
final DateTime _early = DateTime(2026, 3, 4, 9);
final DateTime _late = DateTime(2026, 3, 4, 18);

SyncItem _mine({String status = 'present', DateTime? changedAt}) => SyncItem(
      kind: SyncKind.attendance,
      localKey: '$_uuid:20260304:540',
      fields: <String, Object?>{'status': status, 'weight': 1, 'note': null},
      changedAt: changedAt,
    );

RemoteState _theirs({
  String status = 'present',
  DateTime? editedAt,
  bool deleted = false,
  String key = '$_uuid:20260304:540',
}) {
  final Map<String, Object?> fields = <String, Object?>{
    'status': status,
    'weight': 1,
    'note': null,
  };
  return RemoteState(
    kind: SyncKind.attendance,
    localKey: key,
    remoteId: key,
    hash: deleted
        ? 'deleted'
        : SyncItem(
            kind: SyncKind.attendance,
            localKey: key,
            fields: fields,
          ).hash,
    fields: deleted ? const <String, Object?>{} : fields,
    editedAt: editedAt,
    deleted: deleted,
  );
}

void main() {
  test('rows are sorted by what actually needs asking', () {
    final SyncMergePlan plan = SyncMergePlan.from(
      local: <SyncItem>[
        _mine(),
        SyncItem(
          kind: SyncKind.attendance,
          localKey: '$_uuid:20260305:540',
          fields: const <String, Object?>{'status': 'absent'},
        ),
      ],
      remote: <RemoteState>[
        _theirs(status: 'cancelled', editedAt: _late),
        _theirs(key: '$_uuid:20260306:540', editedAt: _late),
      ],
    );

    expect(plan.differing.single.localKey, '$_uuid:20260304:540');
    expect(plan.onlyHere.single.localKey, '$_uuid:20260305:540');
    expect(plan.onlyThere.single.localKey, '$_uuid:20260306:540');
    expect(plan.agreed, isEmpty);
  });

  test('a row both sides already agree on is never put to the user', () {
    final SyncMergePlan plan = SyncMergePlan.from(
      local: <SyncItem>[_mine()],
      remote: <RemoteState>[_theirs(editedAt: _late)],
    );

    expect(plan.differing, isEmpty);
    expect(plan.agreed, hasLength(1));
  });

  test('a deletion this device never knew about is not a decision', () {
    final SyncMergePlan plan = SyncMergePlan.from(
      local: const <SyncItem>[],
      remote: <RemoteState>[_theirs(deleted: true)],
    );

    expect(plan.isEmpty, isTrue);
  });

  test('a deletion against a mark still held here has to be asked about', () {
    final SyncMergePlan plan = SyncMergePlan.from(
      local: <SyncItem>[_mine(changedAt: _early)],
      remote: <RemoteState>[_theirs(deleted: true, editedAt: _late)],
    );

    final SyncMergeRow row = plan.differing.single;
    // Losing a mark is never the default, even when the deletion looks newer.
    expect(row.newer, SyncSide.here);
  });

  test('the more recently edited side is what a row opens on', () {
    final SyncMergePlan plan = SyncMergePlan.from(
      local: <SyncItem>[_mine(changedAt: _early)],
      remote: <RemoteState>[_theirs(status: 'absent', editedAt: _late)],
    );

    expect(plan.defaults[plan.differing.single.localKey], SyncSide.there);
  });

  test('an undated row from the account cannot win by default', () {
    final SyncMergePlan plan = SyncMergePlan.from(
      local: <SyncItem>[_mine(changedAt: _early)],
      remote: <RemoteState>[_theirs(status: 'absent')],
    );

    expect(plan.defaults[plan.differing.single.localKey], SyncSide.here);
  });
}
