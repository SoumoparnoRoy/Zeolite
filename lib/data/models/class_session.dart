import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';
import 'attendance_record.dart';
import 'attendance_status.dart';
import 'subject.dart';

/// One concrete class on one concrete day — what you actually see on the
/// Today screen.
///
/// Sessions are *derived*, never stored: [ScheduleEngine] expands recurring
/// slots and one-off extras for a date range and attaches any attendance mark.
@immutable
class ClassSession {
  const ClassSession({
    required this.subject,
    required this.date,
    required this.startMinutes,
    required this.endMinutes,
    this.room,
    this.weight = 1,
    this.slotId,
    this.extraClassId,
    this.record,
  });

  final Subject subject;
  final DateTime date;
  final int startMinutes;
  final int endMinutes;
  final String? room;

  /// How many classes this occurrence counts as, carried down from the rule
  /// or the extra that produced it. See [ClassSlot.weight].
  final int weight;

  /// Set when this session came from a recurring rule.
  final int? slotId;

  /// Set when this session is a one-off extra class.
  final int? extraClassId;

  /// The attendance mark, if you have made one.
  final AttendanceRecord? record;

  bool get isExtra => extraClassId != null;

  AttendanceStatus? get status => record?.status;

  bool get isMarked => record != null;

  int get durationMinutes => endMinutes - startMinutes;

  String get key =>
      AttendanceRecord.keyFor(subject.id ?? 0, date, startMinutes);

  /// Local wall-clock start of this session.
  DateTime get startDateTime => DateTime(
        date.year,
        date.month,
        date.day,
        startMinutes ~/ 60,
        startMinutes % 60,
      );

  DateTime get endDateTime => DateTime(
        date.year,
        date.month,
        date.day,
        endMinutes ~/ 60,
        endMinutes % 60,
      );

  bool get isPast => DateTime.now().isAfter(endDateTime);

  bool get isOngoing {
    final DateTime now = DateTime.now();
    return now.isAfter(startDateTime) && now.isBefore(endDateTime);
  }

  bool get isToday => Dates.isSameDay(date, DateTime.now());

  /// A past session with no mark yet — the Today screen nudges you about these.
  bool get needsMarking => !isMarked && isPast;

  ClassSession copyWith({AttendanceRecord? record, bool clearRecord = false}) {
    return ClassSession(
      subject: subject,
      date: date,
      startMinutes: startMinutes,
      endMinutes: endMinutes,
      room: room,
      weight: weight,
      slotId: slotId,
      extraClassId: extraClassId,
      record: clearRecord ? null : (record ?? this.record),
    );
  }

  static int compare(ClassSession a, ClassSession b) {
    final int byDate = Dates.keyOf(a.date).compareTo(Dates.keyOf(b.date));
    if (byDate != 0) return byDate;
    final int byStart = a.startMinutes.compareTo(b.startMinutes);
    if (byStart != 0) return byStart;
    return a.subject.name.compareTo(b.subject.name);
  }
}
