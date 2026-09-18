import '../../core/date_utils.dart';
import '../../data/db/zeolite_repository.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/subject.dart';
import '../../domain/restore_identity.dart';
import '../../domain/sync/sync_target.dart';

import 'remote_fields.dart';

/// Matches rows restored without their identities to the ones an account
/// already holds, so a first sync links them instead of copying them.
class SyncIdentityAdoption {
  SyncIdentityAdoption(this._repository);

  final ZeoliteRepository _repository;

  Future<void> adopt(Map<SyncKind, List<RemoteState>?> remote) async {
    await _adoptSubjects(remote[SyncKind.subject]);

    // Re-read between the two: a class is recognised by its subject, so the
    // subjects have to have settled before anything under them is matched.
    final Map<int, String> subjectUuid = <int, String>{
      for (final Subject s in await _repository.getSubjects())
        if (s.id != null && s.uuid != null) s.id!: s.uuid!,
    };
    await _adoptClasses(
        remote[SyncKind.slot], remote[SyncKind.extraClass], subjectUuid);
  }

  Future<void> _adoptSubjects(List<RemoteState>? theirs) async {
    if (theirs == null || theirs.isEmpty) return;

    final List<Subject> rows = await _repository.getSubjects();
    final Set<String> held = _uuids(rows.map((Subject s) => s.uuid));
    final Set<String> known = _uuids(theirs.map((RemoteState r) => r.localKey));

    final List<Subject> unknown = <Subject>[
      for (final Subject s in rows)
        if (s.uuid == null || !known.contains(s.uuid)) s,
    ];
    if (unknown.isEmpty) return;

    final Map<int, String> adopted = matchByKey(
      unknown: <RowIdentity>[
        for (final Subject s in unknown) RowIdentity(key: subjectKey(s.code)),
      ],
      known: _adoptable(theirs, held,
          (RemoteState r) => subjectKey(readString(r.fields['code']))),
    );

    for (final MapEntry<int, String> entry in adopted.entries) {
      // Not an edit, so it must not be stamped as one: an `updatedAt` of now
      // would have this side win a conflict it should lose.
      await _repository.updateSubject(
        unknown[entry.key].copyWith(uuid: entry.value),
        touch: false,
      );
    }
  }

  Future<void> _adoptClasses(
    List<RemoteState>? theirSlots,
    List<RemoteState>? theirExtras,
    Map<int, String> subjectUuid,
  ) async {
    if (theirSlots != null && theirSlots.isNotEmpty) {
      final List<ClassSlot> rows = await _repository.getSlots();
      final Set<String> held = _uuids(rows.map((ClassSlot s) => s.uuid));
      final Set<String> known =
          _uuids(theirSlots.map((RemoteState r) => r.localKey));
      final List<ClassSlot> unknown = <ClassSlot>[
        for (final ClassSlot s in rows)
          if (s.uuid == null || !known.contains(s.uuid)) s,
      ];

      final Map<int, String> adopted = matchByKey(
        unknown: <RowIdentity>[
          for (final ClassSlot s in unknown)
            RowIdentity(
              key: slotKey(subjectUuid[s.subjectId], s.weekday, s.startMinutes),
            ),
        ],
        known: _adoptable(
          theirSlots,
          held,
          (RemoteState r) => slotKey(
            readString(r.fields['subject']),
            readInt(r.fields['weekday']) ?? -1,
            readInt(r.fields['startMinutes']) ?? -1,
          ),
        ),
      );

      for (final MapEntry<int, String> entry in adopted.entries) {
        await _repository
            .updateSlot(unknown[entry.key].copyWith(uuid: entry.value));
      }
    }

    if (theirExtras == null || theirExtras.isEmpty) return;

    final List<ExtraClass> rows = await _repository.getExtraClasses();
    final Set<String> held = _uuids(rows.map((ExtraClass e) => e.uuid));
    final Set<String> known =
        _uuids(theirExtras.map((RemoteState r) => r.localKey));
    final List<ExtraClass> unknown = <ExtraClass>[
      for (final ExtraClass e in rows)
        if (e.uuid == null || !known.contains(e.uuid)) e,
    ];

    final Map<int, String> adopted = matchByKey(
      unknown: <RowIdentity>[
        for (final ExtraClass e in unknown)
          RowIdentity(
            key: extraKey(
                subjectUuid[e.subjectId], Dates.keyOf(e.date), e.startMinutes),
          ),
      ],
      known: _adoptable(
        theirExtras,
        held,
        (RemoteState r) => extraKey(
          readString(r.fields['subject']),
          readInt(r.fields['date']) ?? -1,
          readInt(r.fields['startMinutes']) ?? -1,
        ),
      ),
    );

    for (final MapEntry<int, String> entry in adopted.entries) {
      await _repository
          .updateExtraClass(unknown[entry.key].copyWith(uuid: entry.value));
    }
  }

  /// The account rows an identity can be taken from. A tombstone is none, and
  /// neither is a uuid this device already holds — that one belongs to another
  /// of its rows, and taking it would leave two on one identity.
  List<RowIdentity> _adoptable(
    List<RemoteState> theirs,
    Set<String> held,
    String? Function(RemoteState) key,
  ) =>
      <RowIdentity>[
        for (final RemoteState state in theirs)
          if (!state.deleted && !held.contains(state.localKey))
            RowIdentity(key: key(state), uuid: state.localKey),
      ];

  Set<String> _uuids(Iterable<String?> values) => <String>{
        for (final String? value in values)
          if (value != null) value,
      };
}
