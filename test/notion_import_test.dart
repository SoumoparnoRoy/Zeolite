import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/notion_export.dart';
import 'package:zeolite/domain/notion_import.dart';

const String _header =
    'Name,Attendance Credit (1/2/0),Course,Date,Held (1/2/0),Held?,L/T/P,'
    'Status';

final DateTime _today = DateTime(2026, 8, 26);

/// Mon 3 Aug 2026.
final DateTime _monday = DateTime(2026, 8, 3);

NotionExport _read(List<String> rows) => NotionExport.read(
      Uint8List.fromList(utf8.encode(<String>[_header, ...rows].join('\n'))),
      today: _today,
    );

NotionPlan _plan(
  NotionExport export, {
  NotionGrouping grouping = NotionGrouping.grouped,
  List<Subject> subjects = const <Subject>[],
  List<ClassSlot> slots = const <ClassSlot>[],
  List<AttendanceRecord> records = const <AttendanceRecord>[],
}) {
  return NotionPlan.from(
    export: export,
    grouping: grouping,
    subjects: subjects,
    slots: slots,
    records: records,
  );
}

void main() {
  final NotionExport twoComponents = _read(<String>[
    'ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present',
    'ABC101L,0,Thermodynamics,Aug 4,1,Yes,Lecture,Absent',
    'ABC101P,2,Thermodynamics,Aug 5,2,Yes,Practical,Present',
  ]);

  group('grouping', () {
    test('grouped puts the lab inside the course and keeps its weight', () {
      final NotionPlan plan = _plan(twoComponents);
      final NotionPlanSubject only = plan.subjects.single;

      expect(only.name, 'Thermodynamics');
      expect(only.classes, 3);
      // One lecture attended plus a practical worth two.
      expect(only.attended, 3);
      expect(only.held, 4);
      expect(only.hasWeighted, isTrue);
    });

    test('separate gives the lab its own subject, everything counting once',
        () {
      final NotionPlan plan =
          _plan(twoComponents, grouping: NotionGrouping.separate);

      expect(
        plan.subjects.map((NotionPlanSubject s) => s.name),
        <String>['Thermodynamics', 'Thermodynamics Lab'],
      );
      final NotionPlanSubject lecture = plan.subjects.first;
      final NotionPlanSubject lab = plan.subjects.last;
      expect(lecture.attended, 1);
      expect(lecture.held, 2);
      expect(lab.attended, 1);
      expect(lab.held, 1);
      expect(lab.hasWeighted, isFalse);
    });

    test('a course already called Lab is not called Lab twice', () {
      // The lab subject reached Notion under its own full name.
      final NotionPlan plan = _plan(
        _read(<String>[
          'HY4L,1,Hydraulics,Aug 3,1,Yes,Lecture,Present',
          'HY4P,2,Hydraulics Lab,Aug 5,1,Yes,Practical,Present',
        ]),
        grouping: NotionGrouping.separate,
      );
      expect(
        plan.subjects.map((NotionPlanSubject s) => s.name),
        <String>['Hydraulics', 'Hydraulics Lab'],
      );
    });

    test('a course whose last word merely ends in lab still gains the suffix',
        () {
      final NotionPlan plan = _plan(
        _read(<String>['ML2P,1,Matlab,Aug 3,1,Yes,Practical,Present']),
        grouping: NotionGrouping.separate,
      );
      expect(plan.subjects.single.name, 'Matlab Lab');
    });

    test('a tutorial is theory, so it shares the theory subject', () {
      final NotionPlan plan = _plan(
        _read(<String>[
          'XY9L,1,Statics,Aug 3,1,Yes,Lecture,Present',
          'XY9T,1,Statics,Aug 4,1,Yes,Tutorial,Present',
          'XY9P,2,Statics,Aug 5,2,Yes,Practical,Present',
        ]),
        grouping: NotionGrouping.separate,
      );
      expect(
        plan.subjects.map((NotionPlanSubject s) => s.name),
        <String>['Statics', 'Statics Lab'],
      );
      // Both the lecture and the tutorial, each counting once.
      expect(plan.subjects.first.held, 2);
    });
  });

  group('the course code', () {
    test('components agree on the part they share', () {
      expect(_plan(twoComponents).subjects.single.code, 'ABC101');
    });

    test('one component keeps its own code whole', () {
      final NotionPlan plan =
          _plan(twoComponents, grouping: NotionGrouping.separate);
      expect(plan.subjects.first.code, 'ABC101L');
      expect(plan.subjects.last.code, 'ABC101P');
    });

    test('components sharing almost nothing get no code at all', () {
      // Better none than a made-up one on the subject card.
      final NotionPlan plan = _plan(_read(<String>[
        'AB,1,Statics,Aug 3,1,Yes,Lecture,Present',
        'ZZ99,1,Statics,Aug 4,1,Yes,Practical,Present',
      ]));
      expect(plan.subjects.single.code, isNull);
    });
  });

  group('placing a mark that has no time on it', () {
    ClassSlot slotAt(int weekday, int start) => ClassSlot(
          subjectId: 1,
          weekday: weekday,
          startMinutes: start,
          endMinutes: start + 60,
          startDate: DateTime(2026, 7, 1),
        );

    const Subject stored =
        Subject(id: 1, name: 'Thermodynamics', colorValue: 0xFF7C6BFF);

    test('a row lands on the class the timetable actually has', () {
      final NotionPlan plan = _plan(
        _read(<String>['ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present']),
        subjects: <Subject>[stored],
        slots: <ClassSlot>[slotAt(DateTime.monday, 11 * 60)],
      );
      final NotionPlacement placed = plan.subjects.single.placements.single;
      expect(placed.startMinutes, 11 * 60);
      expect(placed.scheduled, isTrue);
      expect(plan.subjects.single.unscheduled, 0);
    });

    test('two classes on one day take two different slots', () {
      final NotionPlan plan = _plan(
        _read(<String>[
          'ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present',
          'ABC101P,2,Thermodynamics,Aug 3,2,Yes,Practical,Present',
        ]),
        subjects: <Subject>[stored],
        slots: <ClassSlot>[
          slotAt(DateTime.monday, 9 * 60),
          slotAt(DateTime.monday, 13 * 60),
        ],
      );
      final List<NotionPlacement> placed = plan.subjects.single.placements;
      // Sharing a start time would collapse the two into one mark.
      expect(
        placed.map((NotionPlacement p) => p.startMinutes).toSet(),
        <int>{9 * 60, 13 * 60},
      );
    });

    test('with no class that day the mark lands with no time, unscheduled',
        () {
      final NotionPlan plan = _plan(
        _read(<String>['ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present']),
        subjects: <Subject>[stored],
        slots: <ClassSlot>[slotAt(DateTime.friday, 9 * 60)],
      );
      final NotionPlacement placed = plan.subjects.single.placements.single;
      expect(placed.scheduled, isFalse);
      expect(AttendanceRecord.isTimed(placed.startMinutes), isFalse);
      expect(plan.subjects.single.unscheduled, 1);
    });

    test('two unplaceable rows on one day are still kept apart', () {
      final NotionPlan plan = _plan(
        _read(<String>[
          'ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present',
          'ABC101P,2,Thermodynamics,Aug 3,2,Yes,Practical,Present',
        ]),
        subjects: <Subject>[stored],
      );
      final List<NotionPlacement> placed = plan.subjects.single.placements;
      expect(
        placed.map((NotionPlacement p) => p.startMinutes).toList(),
        <int>[AttendanceRecord.untimed(1), AttendanceRecord.untimed(2)],
      );
    });

    test('a row that brought its own time keeps it', () {
      final NotionPlan plan = _plan(
        NotionExport(
          rows: <NotionRow>[
            NotionRow.read(
              component: 'ABC101L',
              course: 'Thermodynamics',
              kind: NotionKind.lecture,
              date: _monday,
              status: 'present',
              held: 1,
              startMinutes: 14 * 60 + 20,
            ),
          ],
          problems: const <String>[],
        ),
        subjects: <Subject>[stored],
        slots: <ClassSlot>[slotAt(DateTime.monday, 11 * 60)],
      );
      final NotionPlacement placed = plan.subjects.single.placements.single;
      // 11:00 is the only slot, and inference would have taken it.
      expect(placed.startMinutes, 14 * 60 + 20);
      expect(placed.scheduled, isFalse);
    });

    test('a row without a time cannot take the slot a told row is using', () {
      final NotionPlan plan = _plan(
        NotionExport(
          rows: <NotionRow>[
            for (final int? at in <int?>[null, 9 * 60])
              NotionRow.read(
                component: at == null ? 'ABC101L' : 'ABC101P',
                course: 'Thermodynamics',
                kind: NotionKind.lecture,
                date: _monday,
                status: 'present',
                held: 1,
                startMinutes: at,
              ),
          ],
          problems: const <String>[],
        ),
        subjects: <Subject>[stored],
        slots: <ClassSlot>[slotAt(DateTime.monday, 9 * 60)],
      );
      final List<NotionPlacement> placed = plan.subjects.single.placements;
      // Sharing 9:00 would collapse the two into one mark and lose a class.
      expect(
        placed.map((NotionPlacement p) => p.startMinutes).toSet(),
        hasLength(2),
      );
      expect(placed.map((NotionPlacement p) => p.startMinutes), contains(540));
    });

    test('a subject that does not exist yet has nothing to place against', () {
      final NotionPlan plan = _plan(
        _read(<String>['ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present']),
        slots: <ClassSlot>[slotAt(DateTime.monday, 11 * 60)],
      );
      // The slot belongs to subject 1, which this import has not matched.
      expect(plan.subjects.single.placements.single.scheduled, isFalse);
    });
  });

  group('what it would do to what is stored', () {
    const Subject stored =
        Subject(id: 1, name: 'Thermodynamics', colorValue: 0xFF7C6BFF);

    test('an unknown course would be created', () {
      expect(_plan(twoComponents).subjects.single.match, NotionMatch.create);
      expect(_plan(twoComponents).countOf(NotionMatch.create), 1);
    });

    test('a known course with nothing marked in the range is an update', () {
      final NotionPlan plan =
          _plan(twoComponents, subjects: <Subject>[stored]);
      expect(plan.subjects.single.match, NotionMatch.update);
    });

    test('a mark inside the range makes it a conflict', () {
      final NotionPlan plan = _plan(
        twoComponents,
        subjects: <Subject>[stored],
        records: <AttendanceRecord>[
          AttendanceRecord(
            subjectId: 1,
            date: _monday,
            startMinutes: 9 * 60,
            status: AttendanceStatus.present,
          ),
        ],
      );
      expect(plan.subjects.single.match, NotionMatch.overlap);
      expect(plan.subjects.single.marksInRange, 1);
    });

    test('a mark outside the range is left out of it', () {
      final NotionPlan plan = _plan(
        twoComponents,
        subjects: <Subject>[stored],
        records: <AttendanceRecord>[
          AttendanceRecord(
            subjectId: 1,
            date: DateTime(2026, 6, 1),
            startMinutes: 9 * 60,
            status: AttendanceStatus.present,
          ),
        ],
      );
      expect(plan.subjects.single.match, NotionMatch.update);
    });
  });

  group('what the preview has to warn about', () {
    test('labels and contradictions are counted per subject', () {
      final NotionPlan plan = _plan(_read(<String>[
        'ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Proxy',
        'ABC101L,0,Thermodynamics,Aug 4,1,Yes,Lecture,Present',
        'ABC101L,1,Thermodynamics,Aug 5,1,Yes,Lecture,Cancelled',
      ]));
      final NotionPlanSubject only = plan.subjects.single;
      expect(only.labels, <String, int>{'Proxy': 1, 'Cancelled': 1});
      expect(only.suspect, 1);
      // The proxy and the cancellation, which this table credits, both count
      // as attended; only the uncredited row is an absence.
      expect(only.attended, 2);
      expect(only.held, 3);
    });
  });
  group('against a portal that credits a cancelled class', () {
    // The portal prints 76.2% for a course of this shape, which only comes
    // out if a cancelled class counts as attended on both sides.
    final NotionExport export = _read(<String>[
      for (int day = 3; day <= 9; day++)
        'ABC101L,1,Thermodynamics,Aug $day,1,Yes,Lecture,Present',
      'ABC101L,0,Thermodynamics,Aug 10,1,Yes,Lecture,Absent',
      'ABC101L,1,Thermodynamics,Aug 11,1,Yes,Lecture,Cancelled',
      for (int day = 12; day <= 14; day++)
        'ABC101P,2,Thermodynamics,Aug $day,2,Yes,Practical,Present',
      'ABC101P,2,Thermodynamics,Aug 15,2,Yes,Practical,Cancelled',
      'ABC101P,0,Thermodynamics,Aug 16,2,Yes,Practical,Absent',
      'ABC101P,0,Thermodynamics,Aug 17,2,Yes,Practical,Absent',
    ]);

    test('the figures match what the portal prints', () {
      final NotionPlanSubject only = _plan(export).subjects.single;
      expect(only.attended, 16);
      expect(only.held, 21);
      expect((only.attended * 1000 / only.held).round() / 10, 76.2);
    });

    test('its cancelled classes stay cancelled and turn the setting on', () {
      final NotionPlan plan = _plan(export);
      expect(plan.countsCancelled, isTrue);
      expect(plan.creditedOtherwise, 0);
      expect(
        plan.subjects.single.placements
            .where((NotionPlacement p) =>
                p.row.status == AttendanceStatus.cancelled)
            .length,
        2,
      );
    });
  });

  test('a row the table does not count stays at nothing when labs split', () {
    final NotionPlan plan = _plan(
      _read(<String>[
        'ABC101P,0,Thermodynamics,Aug 3,0,No,Practical,Present',
        'ABC101P,2,Thermodynamics,Aug 4,2,Yes,Practical,Present',
      ]),
      grouping: NotionGrouping.separate,
    );
    expect(
      plan.subjects.single.placements.map((NotionPlacement p) => p.weight),
      <int>[0, 1],
    );
    expect(plan.subjects.single.held, 1);
  });

  test('each subject takes the type its rows mostly say, in their words', () {
    final NotionPlan plan = _plan(
      _read(<String>[
        'ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present',
        'ABC101L,1,Thermodynamics,Aug 4,1,Yes,Lecture,Present',
        'ABC101T,1,Thermodynamics,Aug 5,1,Yes,Tutorial,Present',
        'ABC101P,2,Thermodynamics,Aug 6,2,Yes,Lab,Present',
      ]),
      grouping: NotionGrouping.separate,
    );
    final Map<String, String?> types = <String, String?>{
      for (final NotionPlanSubject s in plan.subjects) s.name: s.categoryName,
    };
    expect(types, <String, String?>{
      'Thermodynamics': 'Lecture',
      'Thermodynamics Lab': 'Lab',
    });
  });

  test('rows left without a type count only if the student says so', () {
    final NotionExport export = _read(<String>[
      'ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present',
      'ABC101L,0,Thermodynamics,Aug 4,0,No,,Present',
    ]);
    final NotionPlan counted = _plan(export);
    final NotionPlan asTheyAre = NotionPlan.from(
      export: export,
      grouping: NotionGrouping.grouped,
      subjects: const <Subject>[],
      slots: const <ClassSlot>[],
      records: const <AttendanceRecord>[],
      countUntyped: false,
    );

    expect(counted.untyped, 1);
    expect(counted.subjects.single.held, 2);
    expect(asTheyAre.subjects.single.held, 1);
  });

  test('a table that mostly does not credit cancellations turns it off', () {
    final NotionPlan plan = _plan(_read(<String>[
      'ABC101L,1,Thermodynamics,Aug 3,1,Yes,Lecture,Present',
      'ABC101L,1,Thermodynamics,Aug 4,1,Yes,Lecture,Cancelled',
      'ABC101L,0,Thermodynamics,Aug 5,1,Yes,Lecture,Cancelled',
      'ABC101L,0,Thermodynamics,Aug 6,1,Yes,Lecture,Cancelled',
    ]));
    expect(plan.countsCancelled, isFalse);
    expect(plan.creditedOtherwise, 1);
    expect(plan.subjects.single.attended, 1);
    expect(plan.subjects.single.held, 1);
  });

}
