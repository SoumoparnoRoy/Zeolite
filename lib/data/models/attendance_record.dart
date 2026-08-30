import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';
import 'attendance_status.dart';

/// A mark you made against one class occurrence.
///
/// Occurrences are identified by the natural key
/// `(subjectId, dateKey, startMinutes)` rather than by a slot id. That way a
/// mark survives editing or deleting the recurring rule it came from, and a
/// one-off class and a recurring class at the same time can't collide.
@immutable
class AttendanceRecord {
  const AttendanceRecord({
    this.id,
    required this.subjectId,
    required this.date,
    required this.startMinutes,
    required this.status,
    this.weight = 1,
    this.tagId,
    this.note,
    this.markedAt,
  });

  final int? id;
  final int subjectId;
  final DateTime date;
  final int startMinutes;
  final AttendanceStatus status;

  /// How many classes this one occurrence is worth.
  ///
  /// Copied off the occurrence when the mark is made rather than read back
  /// through the rule, so correcting a slot's length later cannot silently
  /// restate a term of history.
  final int weight;

  /// Optional label from the user's own list — "Proxy", "Online". Null means
  /// untagged, which is what every mark made before tags existed still is.
  final int? tagId;

  final String? note;
  final DateTime? markedAt;

  /// Composite key used to look a record up from an occurrence.
  static String keyFor(int subjectId, DateTime date, int startMinutes) =>
      '$subjectId:${Dates.keyOf(date)}:$startMinutes';

  String get key => keyFor(subjectId, date, startMinutes);

  AttendanceRecord copyWith({
    int? id,
    int? subjectId,
    DateTime? date,
    int? startMinutes,
    AttendanceStatus? status,
    int? weight,
    int? tagId,
    bool clearTag = false,
    String? note,
    DateTime? markedAt,
  }) {
    return AttendanceRecord(
      id: id ?? this.id,
      subjectId: subjectId ?? this.subjectId,
      date: date ?? this.date,
      startMinutes: startMinutes ?? this.startMinutes,
      status: status ?? this.status,
      weight: weight ?? this.weight,
      tagId: clearTag ? null : (tagId ?? this.tagId),
      note: note ?? this.note,
      markedAt: markedAt ?? this.markedAt,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'subject_id': subjectId,
        'date': Dates.keyOf(date),
        'start_minutes': startMinutes,
        'status': status.name,
        'weight': weight,
        'tag_id': tagId,
        'note': note,
        'marked_at': (markedAt ?? DateTime.now()).millisecondsSinceEpoch,
      };

  factory AttendanceRecord.fromMap(Map<String, Object?> map) {
    return AttendanceRecord(
      id: map['id'] as int?,
      subjectId: (map['subject_id'] as int?) ?? 0,
      date: Dates.fromKey((map['date'] as int?) ?? 19700101),
      startMinutes: (map['start_minutes'] as int?) ?? 0,
      status: AttendanceStatus.fromName(map['status'] as String?) ??
          AttendanceStatus.present,
      // Zero is a real weight — a class held but not assessed. Negative is
      // not, and a hand-edited backup is where one would come from.
      weight: math.max(0, (map['weight'] as num?)?.toInt() ?? 1),
      tagId: map['tag_id'] as int?,
      note: map['note'] as String?,
      markedAt: map['marked_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['marked_at']! as int),
    );
  }
}
