import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/schedule_engine.dart';
import 'package:zeolite/domain/untimed_match.dart';

final DateTime _monday = DateTime(2026, 8, 3);
const int _lecture = 1;
const int _tutorial = 3;

ClassSlot _slot(int id, int start, {int subjectId = 1, int? categoryId}) =>
    ClassSlot(
      id: id,
      subjectId: subjectId,
      weekday: DateTime.monday,
      startMinutes: start,
      endMinutes: start + 50,
      categoryId: categoryId,
      startDate: _monday,
    );

AttendanceRecord _mark(
  int start, {
  int subjectId = 1,
  int? categoryId,
  AttendanceStatus status = AttendanceStatus.present,
}) =>
    AttendanceRecord(
      subjectId: subjectId,
      date: _monday,
      startMinutes: start,
      status: status,
      categoryId: categoryId,
    );

List<UntimedMatch> _match(
  List<ClassSlot> slots,
  List<AttendanceRecord> records, {
  Set<int>? subjects,
}) {
  final ScheduleEngine engine = ScheduleEngine(
    subjects: const <Subject>[
      Subject(id: 1, name: 'Course 1', colorValue: 0, categoryId: _lecture),
      Subject(id: 2, name: 'Course 2', colorValue: 0),
    ],
    slots: slots,
    extras: const <ExtraClass>[],
    holidays: const <Holiday>[],
    records: records,
  );
  return matchUntimed(engine: engine, records: records, subjects: subjects);
}

void main() {
  test('untimed marks take free classes by type, then in order', () {
    final List<UntimedMatch> matches = _match(
      <ClassSlot>[_slot(1, 540), _slot(2, 660, categoryId: _tutorial)],
      <AttendanceRecord>[
        _mark(AttendanceRecord.untimed(1), categoryId: _tutorial),
        _mark(AttendanceRecord.untimed(2)),
        _mark(AttendanceRecord.untimed(3)),
      ],
    );

    expect(
      <(int, int)>[
        for (final UntimedMatch m in matches)
          (m.record.startMinutes, m.moved.startMinutes),
      ],
      unorderedEquals(<(int, int)>[(-1, 660), (-2, 540)]),
    );
    expect(matches.every((UntimedMatch m) => m.moved.status == m.record.status),
        isTrue);
  });

  test('a class marked by hand, or another subject, is never taken', () {
    final List<ClassSlot> slots = <ClassSlot>[
      _slot(1, 540),
      _slot(2, 600, subjectId: 2),
    ];
    final AttendanceRecord untimed = _mark(AttendanceRecord.untimed(1));

    expect(
      _match(slots, <AttendanceRecord>[
        untimed,
        _mark(540, status: AttendanceStatus.absent),
      ]),
      isEmpty,
    );
    expect(_match(slots, <AttendanceRecord>[untimed], subjects: <int>{2}),
        isEmpty);
  });
}
