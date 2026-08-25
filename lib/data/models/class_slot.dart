import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';
import 'attendance_record.dart';

/// A recurring weekly class: "Physics, every Tuesday 09:00–10:30, from 4 Aug".
///
/// A slot is a *rule*, not a row per week. Individual occurrences are derived
/// on the fly by [ScheduleEngine], which keeps the database tiny and means
/// editing the rule instantly reshapes every future week.
@immutable
class ClassSlot {
  const ClassSlot({
    this.id,
    required this.subjectId,
    required this.weekday,
    required this.startMinutes,
    required this.endMinutes,
    this.room,
    this.weight = 1,
    required this.startDate,
    this.endDate,
  });

  final int? id;
  final int subjectId;

  /// 1 = Monday … 7 = Sunday, matching [DateTime.weekday].
  final int weekday;

  final int startMinutes;
  final int endMinutes;
  final String? room;

  /// How many classes one occurrence of this rule counts as. 1 unless the
  /// institution counts a longer class more than once.
  final int weight;

  /// First date this rule applies from (inclusive). Recurrence runs forward
  /// from here, which is exactly the "repeats every week from now on" model.
  final DateTime startDate;

  /// Optional last date (inclusive). Null means "until the semester ends".
  final DateTime? endDate;

  int get durationMinutes => endMinutes - startMinutes;

  String get weekdayName => kWeekdayNamesLong[weekday - 1];

  String get weekdayShortName => kWeekdayNamesShort[weekday - 1];

  /// Whether this rule can produce an occurrence on [date].
  /// Marks carry no slot id, so ownership is the recurrence test plus the
  /// start time that produced them.
  bool covers(AttendanceRecord record) =>
      record.subjectId == subjectId &&
      record.startMinutes == startMinutes &&
      appliesOn(record.date);

  bool appliesOn(DateTime date) {
    if (date.weekday != weekday) return false;
    final int key = Dates.keyOf(date);
    if (key < Dates.keyOf(startDate)) return false;
    if (endDate != null && key > Dates.keyOf(endDate!)) return false;
    return true;
  }

  ClassSlot copyWith({
    int? id,
    int? subjectId,
    int? weekday,
    int? startMinutes,
    int? endMinutes,
    String? room,
    int? weight,
    DateTime? startDate,
    DateTime? endDate,
    bool clearEndDate = false,
  }) {
    return ClassSlot(
      id: id ?? this.id,
      subjectId: subjectId ?? this.subjectId,
      weekday: weekday ?? this.weekday,
      startMinutes: startMinutes ?? this.startMinutes,
      endMinutes: endMinutes ?? this.endMinutes,
      room: room ?? this.room,
      weight: weight ?? this.weight,
      startDate: startDate ?? this.startDate,
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'subject_id': subjectId,
        'weekday': weekday,
        'start_minutes': startMinutes,
        'end_minutes': endMinutes,
        'room': room,
        'weight': weight,
        'start_date': Dates.keyOf(startDate),
        'end_date': endDate == null ? null : Dates.keyOf(endDate!),
      };

  factory ClassSlot.fromMap(Map<String, Object?> map) {
    return ClassSlot(
      id: map['id'] as int?,
      subjectId: (map['subject_id'] as int?) ?? 0,
      weekday: (map['weekday'] as int?) ?? DateTime.monday,
      startMinutes: (map['start_minutes'] as int?) ?? 0,
      endMinutes: (map['end_minutes'] as int?) ?? 0,
      room: map['room'] as String?,
      weight: math.max(1, (map['weight'] as num?)?.toInt() ?? 1),
      startDate: Dates.fromKey((map['start_date'] as int?) ?? 19700101),
      endDate: map['end_date'] == null
          ? null
          : Dates.fromKey(map['end_date']! as int),
    );
  }
}
