import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/class_category.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/holiday.dart';
import '../../data/models/room.dart';
import '../../data/models/subject.dart';
import '../../data/models/tag.dart';
import '../../data/settings/app_settings.dart';

/// What a synced row is.
///
/// Only [slot] and [extraClass] carry a uuid. The rest key on something the
/// data already has — a holiday on its date, a tag, room or category on its
/// name — which is both smaller and better: two devices set up separately
/// still agree that "Proxy" is "Proxy", where two issued ids never would.
enum SyncKind {
  attendance,
  subject,
  category,
  room,
  tag,
  holiday,
  slot,
  extraClass,

  /// The handful of settings that decide which occurrences exist at all.
  /// One row, because they are one document and not a table.
  settings;

  static SyncKind? fromName(String? value) {
    if (value == null) return null;
    for (final SyncKind kind in SyncKind.values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// Who created the row on the far side.
///
/// A page the app never made is never archived by it — deleting the mark drops
/// the link and leaves the page alone.
enum SyncOrigin {
  app,
  remote;

  static SyncOrigin? fromName(String? value) {
    if (value == null) return null;
    for (final SyncOrigin origin in SyncOrigin.values) {
      if (origin.name == value) return origin;
    }
    return null;
  }
}

/// One local row offered to a target, reduced to what a target could hold.
@immutable
class SyncItem {
  const SyncItem({
    required this.kind,
    required this.localKey,
    required this.fields,
    this.changedAt,
  });

  /// The key a target files a mark under.
  ///
  /// Deliberately not [AttendanceRecord.key], which leads with `subjectId` —
  /// an autoincrement that numbers the same course differently on every
  /// install, so a second device would file the mark under the wrong subject.
  static String keyFor(String subjectUuid, DateTime date, int startMinutes) =>
      '$subjectUuid:${Dates.keyOf(date)}:$startMinutes';

  /// A mark, as a target would see it.
  ///
  /// The tag travels by name rather than by `tagId`, which points at a row in
  /// the local tag list and means nothing anywhere else.
  factory SyncItem.attendance(
    AttendanceRecord record,
    String subjectUuid, {
    String? tagName,
  }) {
    return SyncItem(
      kind: SyncKind.attendance,
      localKey: keyFor(subjectUuid, record.date, record.startMinutes),
      fields: <String, Object?>{
        'status': record.status.name,
        'weight': record.weight,
        'note': record.note,
        'tag': tagName,
      },
      changedAt: record.markedAt,
    );
  }

  /// A subject travels too, or a second device receives marks keyed on a uuid
  /// it cannot name. `id` stays behind; the category travels **by name**,
  /// since its own id means nothing on the far side.
  factory SyncItem.subject(Subject subject, {String? categoryName}) {
    return SyncItem(
      kind: SyncKind.subject,
      localKey: subject.uuid ?? '',
      fields: <String, Object?>{
        'name': subject.name,
        'code': subject.code,
        'teacher': subject.teacher,
        'color': subject.colorValue,
        'targetPercent': subject.targetPercent,
        'priorHeld': subject.priorHeld,
        'priorAttended': subject.priorAttended,
        'expectedTotal': subject.expectedTotal,
        'category': categoryName,
      },
      changedAt: subject.updatedAt ?? subject.createdAt,
    );
  }

  factory SyncItem.category(ClassCategory category) => SyncItem(
        kind: SyncKind.category,
        localKey: category.name,
        fields: <String, Object?>{
          'defaultMinutes': category.defaultDurationMinutes,
        },
        changedAt: category.createdAt,
      );

  /// Rooms and tags are a name and an order, and the name is the key — so the
  /// only thing left to carry is where the user put it in their list.
  factory SyncItem.room(Room room) => SyncItem(
        kind: SyncKind.room,
        localKey: room.name,
        fields: <String, Object?>{'position': room.position},
      );

  factory SyncItem.tag(Tag tag) => SyncItem(
        kind: SyncKind.tag,
        localKey: tag.name,
        fields: <String, Object?>{'position': tag.position},
      );

  factory SyncItem.holiday(Holiday holiday) => SyncItem(
        kind: SyncKind.holiday,
        localKey: '${Dates.keyOf(holiday.date)}',
        fields: <String, Object?>{'name': holiday.name},
      );

  /// The rule, not its occurrences. `subject` is the far side's key for the
  /// course, never the local row id.
  factory SyncItem.slot(ClassSlot slot, String subjectUuid) => SyncItem(
        kind: SyncKind.slot,
        localKey: slot.uuid ?? '',
        fields: <String, Object?>{
          'subject': subjectUuid,
          'weekday': slot.weekday,
          'startMinutes': slot.startMinutes,
          'endMinutes': slot.endMinutes,
          'room': slot.room,
          'weight': slot.weight,
          'startDate': Dates.keyOf(slot.startDate),
          'endDate':
              slot.endDate == null ? null : Dates.keyOf(slot.endDate!),
        },
      );

  factory SyncItem.extraClass(ExtraClass extra, String subjectUuid) =>
      SyncItem(
        kind: SyncKind.extraClass,
        localKey: extra.uuid ?? '',
        fields: <String, Object?>{
          'subject': subjectUuid,
          'date': Dates.keyOf(extra.date),
          'startMinutes': extra.startMinutes,
          'endMinutes': extra.endMinutes,
          'room': extra.room,
          'weight': extra.weight,
          'note': extra.note,
        },
      );

  /// Only what shapes the timetable. Theme, notifications and the backup
  /// folder stay on the device that set them: they describe the device, not
  /// the course, and a folder grant is meaningless anywhere else.
  ///
  /// One row rather than a table, so it is the one synced thing with no
  /// natural key of its own — [settingsKey] is simply where it lives.
  factory SyncItem.settings(AppSettings settings, {DateTime? changedAt}) =>
      SyncItem(
        kind: SyncKind.settings,
        localKey: settingsKey,
        fields: <String, Object?>{
          'semesterStart': settings.semesterStart == null
              ? null
              : Dates.keyOf(settings.semesterStart!),
          'semesterEnd': settings.semesterEnd == null
              ? null
              : Dates.keyOf(settings.semesterEnd!),
          'targetPercent': settings.targetPercent,
          'defaultClassMinutes': settings.defaultClassDurationMinutes,
          'dayStartMinutes': settings.dayStartMinutes,
          'dayEndMinutes': settings.dayEndMinutes,
          'blockMinutes': settings.blockMinutes,
          'breakAfterBlock': settings.breakAfterBlock,
          'breakMinutes': settings.breakMinutes,
        },
        changedAt: changedAt,
      );

  static const String settingsKey = 'schedule';

  final SyncKind kind;

  /// `AttendanceRecord.keyFor` — subject, day and start time. Stable across
  /// editing or deleting the rule the mark came from, which is why the ledger
  /// keys on it rather than on a row id.
  final String localKey;

  final Map<String, Object?> fields;

  /// When the row was last touched locally. Compared against the target's edit
  /// time to describe a conflict, never to resolve one.
  final DateTime? changedAt;

  /// Fingerprint of [fields]: two items with the same hash need no push.
  String get hash => _fnv1a(_canonical);

  /// Null fields are left out rather than written as `k=null`, so a field
  /// that is unset hashes the same as one that was never there. That is what
  /// lets the payload gain a field — a subject's category, a mark's tag —
  /// without every row that does not use it looking changed on both sides.
  String get _canonical {
    final List<String> keys = fields.keys
        .where((String k) => fields[k] != null)
        .toList()
      ..sort();
    return keys.map((String k) => '$k=${fields[k]}').join(' ');
  }
}

/// This ends up in `remote_links` and is compared across app restarts, so
/// `String.hashCode` is no good — it is only promised to hold within one run.
String _fnv1a(String input) {
  int hash = 0x811c9dc5;
  for (final int unit in input.codeUnits) {
    hash = (hash ^ unit) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// The ledger row tying one local key to one page on the far side.
@immutable
class RemoteLink {
  const RemoteLink({
    this.id,
    required this.target,
    required this.kind,
    required this.localKey,
    required this.remoteId,
    required this.localHash,
    required this.remoteHash,
    required this.origin,
    this.syncedAt,
  });

  final int? id;

  /// Which target the link belongs to — one install can hold more than one.
  final String target;

  final SyncKind kind;
  final String localKey;
  final String remoteId;

  /// What was last pushed, and what the target held when last seen. A change
  /// on either side shows as a difference from its own stored hash, which is
  /// what lets both be found in the same pass.
  final String localHash;
  final String remoteHash;

  final SyncOrigin origin;
  final DateTime? syncedAt;

  RemoteLink copyWith({
    String? remoteId,
    String? localHash,
    String? remoteHash,
    DateTime? syncedAt,
  }) {
    return RemoteLink(
      id: id,
      target: target,
      kind: kind,
      localKey: localKey,
      remoteId: remoteId ?? this.remoteId,
      localHash: localHash ?? this.localHash,
      remoteHash: remoteHash ?? this.remoteHash,
      origin: origin,
      syncedAt: syncedAt ?? this.syncedAt,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'target': target,
        'kind': kind.name,
        'local_key': localKey,
        'remote_id': remoteId,
        'local_hash': localHash,
        'remote_hash': remoteHash,
        'synced_at': (syncedAt ?? DateTime.now()).millisecondsSinceEpoch,
        'origin': origin.name,
      };

  factory RemoteLink.fromMap(Map<String, Object?> map) {
    return RemoteLink(
      id: map['id'] as int?,
      target: (map['target'] as String?) ?? '',
      kind: SyncKind.fromName(map['kind'] as String?) ?? SyncKind.attendance,
      localKey: (map['local_key'] as String?) ?? '',
      remoteId: (map['remote_id'] as String?) ?? '',
      localHash: (map['local_hash'] as String?) ?? '',
      remoteHash: (map['remote_hash'] as String?) ?? '',
      origin: SyncOrigin.fromName(map['origin'] as String?) ?? SyncOrigin.app,
      syncedAt: map['synced_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['synced_at']! as int),
    );
  }
}

/// One row as the target holds it right now.
@immutable
class RemoteState {
  const RemoteState({
    required this.kind,
    required this.localKey,
    required this.remoteId,
    required this.hash,
    this.fields = const <String, Object?>{},
    this.editedAt,
    this.deleted = false,
  });

  final SyncKind kind;

  /// The target resolves its own page back to a local key through its mapping,
  /// so the planner never has to know how a page is shaped.
  final String localKey;

  final String remoteId;
  final String hash;

  /// What the row holds, in the same shape [SyncItem.fields] uses. Carried on
  /// the state rather than fetched again per row: knowing a row changed is no
  /// use without knowing what it changed to, and a target that has just read
  /// the collection already has this in hand. Empty on a tombstone.
  final Map<String, Object?> fields;

  final DateTime? editedAt;

  /// A tombstone: the row was deleted on another device. Removing the document
  /// outright would leave every other device holding a row and a link with
  /// nothing to compare against, and the next push would put it straight back.
  final bool deleted;
}

/// Why a call did not go through. The coordinator treats these differently:
/// [auth] stops the run and asks the user, the rest are retried with backoff.
enum SyncFailure { offline, auth, rateLimited, rejected, unknown }

/// The result of one create, update or archive.
@immutable
class SyncOutcome {
  const SyncOutcome.done({required this.remoteId, required this.remoteHash})
      : failure = null,
        message = null;

  const SyncOutcome.failed(this.failure, {this.message})
      : remoteId = null,
        remoteHash = null;

  final String? remoteId;
  final String? remoteHash;
  final SyncFailure? failure;
  final String? message;

  bool get ok => failure == null;
}

/// Somewhere attendance can be mirrored to.
///
/// Deliberately free of HTTP and of any one service's vocabulary: a second
/// integration is one more implementation of this, and nothing above it moves.
abstract class SyncTarget {
  /// Stored in `remote_links.target`, so it has to stay stable once shipped.
  String get id;

  /// True for a target holding only what this app wrote, where a pull is the
  /// user's own second device. False where a person edits by hand and a pull
  /// has to go through the preview first.
  bool get trustsPulls;

  /// Whether a linked row the far side no longer holds should be pushed again.
  /// True for a store this app owns, where the row going missing is damage to
  /// repair. False where a person works by hand and deleted it on purpose.
  bool get recreatesMissingRows => false;

  /// What this target keeps. Notion holds attendance and nothing else, and a
  /// target that answered "fine" to a room or a settings row would leave a
  /// ledger entry pointing at a page nobody ever made.
  Set<SyncKind> get kinds => SyncKind.values.toSet();

  /// What the target holds now, or null when it could not be read this run —
  /// the planner then pushes without claiming to know the far side.
  Future<List<RemoteState>?> fetch(SyncKind kind);

  Future<SyncOutcome> create(SyncItem item);

  Future<SyncOutcome> update(SyncItem item, String remoteId);

  /// [kind] is carried because a target files each kind separately, and a
  /// tombstone written into the wrong collection would delete nothing and
  /// resurrect the row on the next run.
  Future<SyncOutcome> archive(SyncKind kind, String remoteId);
}
