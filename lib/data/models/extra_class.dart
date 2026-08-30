import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';

/// A one-off class that is not part of the weekly pattern — a make-up lecture,
/// an extra lab, a rescheduled tutorial.
@immutable
class ExtraClass {
  const ExtraClass({
    this.id,
    this.uuid,
    required this.subjectId,
    required this.date,
    required this.startMinutes,
    required this.endMinutes,
    this.room,
    this.weight = 1,
    this.note,
  });

  final int? id;

  /// See [ClassSlot.uuid] — a one-off class is editable in every field that
  /// could otherwise identify it.
  final String? uuid;

  final int subjectId;
  final DateTime date;
  final int startMinutes;
  final int endMinutes;
  final String? room;

  /// See [ClassSlot.weight] — a one-off lab counts the same as a recurring one.
  final int weight;

  final String? note;

  int get durationMinutes => endMinutes - startMinutes;

  ExtraClass copyWith({
    int? id,
    String? uuid,
    int? subjectId,
    DateTime? date,
    int? startMinutes,
    int? endMinutes,
    String? room,
    int? weight,
    String? note,
  }) {
    return ExtraClass(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      subjectId: subjectId ?? this.subjectId,
      date: date ?? this.date,
      startMinutes: startMinutes ?? this.startMinutes,
      endMinutes: endMinutes ?? this.endMinutes,
      room: room ?? this.room,
      weight: weight ?? this.weight,
      note: note ?? this.note,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        if (uuid != null) 'uuid': uuid,
        'subject_id': subjectId,
        'date': Dates.keyOf(date),
        'start_minutes': startMinutes,
        'end_minutes': endMinutes,
        'room': room,
        'weight': weight,
        'note': note,
      };

  factory ExtraClass.fromMap(Map<String, Object?> map) {
    return ExtraClass(
      id: map['id'] as int?,
      uuid: map['uuid'] as String?,
      subjectId: (map['subject_id'] as int?) ?? 0,
      date: Dates.fromKey((map['date'] as int?) ?? 19700101),
      startMinutes: (map['start_minutes'] as int?) ?? 0,
      endMinutes: (map['end_minutes'] as int?) ?? 0,
      room: map['room'] as String?,
      weight: math.max(0, (map['weight'] as num?)?.toInt() ?? 1),
      note: map['note'] as String?,
    );
  }
}
