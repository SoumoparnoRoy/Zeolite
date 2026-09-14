import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';
import 'class_slot.dart';

/// One week of a weekly rule doing something different, or not happening.
///
/// The rule stays a rule: this says only how a single date departs from it, so
/// the room changing for one Tuesday does not become a second [ClassSlot] with
/// its own start and end dates to keep in step.
///
/// Every field but [skipped] is nullable and null means *inherit* — a room-only
/// exception carries a room and nothing else. That matters beyond tidiness: a
/// copy of the rule's subject and start time frozen here would silently stop
/// tracking a later edit to the rule, and the two would disagree about which
/// attendance key the occurrence owns.
@immutable
class SlotOverride {
  const SlotOverride({
    this.id,
    this.uuid,
    required this.slotId,
    required this.date,
    this.skipped = false,
    this.subjectId,
    this.startMinutes,
    this.endMinutes,
    this.room,
  });

  final int? id;

  /// See [ClassSlot.uuid]. Carried for the same reason and unused until
  /// overrides are synced.
  final String? uuid;

  final int slotId;

  /// The single day this applies to.
  final DateTime date;

  /// The occurrence does not happen at all. Nothing else is read when set.
  final bool skipped;

  final int? subjectId;
  final int? startMinutes;
  final int? endMinutes;
  final String? room;

  /// Whether this changes anything. A row that overrides nothing and skips
  /// nothing is the same as having no row, and is deleted rather than stored.
  bool get isEmpty =>
      !skipped &&
      subjectId == null &&
      startMinutes == null &&
      endMinutes == null &&
      room == null;

  /// The rule as this date sees it.
  ///
  /// Returns null for a skipped date, which is how the engine drops it. The id
  /// and the recurrence bounds stay the rule's: this is one occurrence wearing
  /// different clothes, not a slot of its own.
  ClassSlot? applyTo(ClassSlot slot) {
    if (skipped) return null;
    return ClassSlot(
      id: slot.id,
      uuid: slot.uuid,
      subjectId: subjectId ?? slot.subjectId,
      weekday: slot.weekday,
      startMinutes: startMinutes ?? slot.startMinutes,
      endMinutes: endMinutes ?? slot.endMinutes,
      room: room ?? slot.room,
      weight: slot.weight,
      startDate: slot.startDate,
      endDate: slot.endDate,
    );
  }

  SlotOverride copyWith({
    int? id,
    String? uuid,
    int? slotId,
    DateTime? date,
    bool? skipped,
    int? subjectId,
    int? startMinutes,
    int? endMinutes,
    String? room,
  }) {
    return SlotOverride(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      slotId: slotId ?? this.slotId,
      date: date ?? this.date,
      skipped: skipped ?? this.skipped,
      subjectId: subjectId ?? this.subjectId,
      startMinutes: startMinutes ?? this.startMinutes,
      endMinutes: endMinutes ?? this.endMinutes,
      room: room ?? this.room,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        if (uuid != null) 'uuid': uuid,
        'slot_id': slotId,
        'date': Dates.keyOf(date),
        'skipped': skipped ? 1 : 0,
        'subject_id': subjectId,
        'start_minutes': startMinutes,
        'end_minutes': endMinutes,
        'room': room,
      };

  factory SlotOverride.fromMap(Map<String, Object?> map) {
    return SlotOverride(
      id: map['id'] as int?,
      uuid: map['uuid'] as String?,
      slotId: (map['slot_id'] as int?) ?? 0,
      date: Dates.fromKey((map['date'] as int?) ?? 19700101),
      skipped: ((map['skipped'] as int?) ?? 0) != 0,
      subjectId: map['subject_id'] as int?,
      startMinutes: map['start_minutes'] as int?,
      endMinutes: map['end_minutes'] as int?,
      room: map['room'] as String?,
    );
  }
}
