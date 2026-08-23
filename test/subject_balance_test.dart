import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_stats.dart';

Subject subject({
  int id = 1,
  String name = 'Physics',
  int priorHeld = 0,
  int priorAttended = 0,
  int? expectedTotal,
}) {
  return Subject(
    id: id,
    name: name,
    colorValue: 0xFF7C6BFF,
    priorHeld: priorHeld,
    priorAttended: priorAttended,
    expectedTotal: expectedTotal,
  );
}

SubjectStats statsOf({
  required Subject of,
  int present = 0,
  int absent = 0,
  double target = 0.75,
  int fromSlots = 0,
}) {
  return SubjectStats(
    subject: of,
    present: present,
    absent: absent,
    cancelled: 0,
    target: target,
    plannedFromSlots: fromSlots,
  );
}

void main() {
  group('a carried balance', () {
    test('counts towards the percentage without becoming a mark', () {
      final SubjectStats stats = statsOf(
        of: subject(priorHeld: 16, priorAttended: 14),
        present: 2,
        absent: 1,
      );
      expect(stats.held, 19);
      expect(stats.attended, 16);
      expect(stats.present, 2);
      expect(stats.absent, 1);
    });

    test('gives a subject a verdict before anything is marked', () {
      final SubjectStats stats = statsOf(
        of: subject(priorHeld: 18, priorAttended: 12),
      );
      expect(stats.hasData, isTrue);
      expect(stats.health, isNot(AttendanceHealth.empty));
      expect(stats.percent, closeTo(66.67, 0.01));
    });

    test('moves how many can be skipped and how many must be attended', () {
      final SubjectStats safe =
          statsOf(of: subject(priorHeld: 10, priorAttended: 10));
      expect(safe.canSkip, 3);

      final SubjectStats behind =
          statsOf(of: subject(priorHeld: 10, priorAttended: 6));
      expect(behind.meetsTarget, isFalse);
      // 6/10 at a 75% target: (0.75*10 - 6) / 0.25 = 6 in a row.
      expect(behind.needToAttend, 6);
    });

    test('is clamped on the way out of the database', () {
      final Subject read = Subject.fromMap(<String, Object?>{
        'name': 'Physics',
        'color': 0xFF7C6BFF,
        'created_at': 0,
        'prior_held': 5,
        'prior_attended': 9,
      });
      expect(read.priorAttended, 5);

      final Subject negative = Subject.fromMap(<String, Object?>{
        'name': 'Physics',
        'color': 0xFF7C6BFF,
        'created_at': 0,
        'prior_held': -3,
      });
      expect(negative.priorHeld, 0);
    });

    test('survives a round trip through a backup', () {
      const Subject before = Subject(
        id: 3,
        name: 'Physics',
        colorValue: 0xFF7C6BFF,
        priorHeld: 16,
        priorAttended: 14,
        expectedTotal: 18,
      );
      final Subject after = Subject.fromMap(before.toMap());
      expect(after.priorHeld, 16);
      expect(after.priorAttended, 14);
      expect(after.expectedTotal, 18);
    });

    test('a backup written before any of this still reads', () {
      final Subject old = Subject.fromMap(<String, Object?>{
        'name': 'Physics',
        'color': 0xFF7C6BFF,
        'created_at': 0,
      });
      expect(old.priorHeld, 0);
      expect(old.priorAttended, 0);
      expect(old.expectedTotal, isNull);
    });

    test('a row of zeroes reads as nothing marked, not as zero percent', () {
      final SubjectStats stats = statsOf(
          of: subject(priorHeld: 0, priorAttended: 0, expectedTotal: 0));
      expect(stats.hasData, isFalse);
      expect(stats.health, AttendanceHealth.empty);
      expect(stats.remainingPlanned, 0);
    });
  });

  group('a term total', () {
    test('derives what is left, so nothing has to be kept up to date', () {
      final Subject of =
          subject(priorHeld: 16, priorAttended: 14, expectedTotal: 18);
      expect(statsOf(of: of).remainingPlanned, 2);
      // Two more marked here and the figure follows on its own.
      expect(statsOf(of: of, present: 1, absent: 1).remainingPlanned, 0);
    });

    test('never goes negative once the total is passed', () {
      final SubjectStats stats = statsOf(
        of: subject(priorHeld: 20, priorAttended: 18, expectedTotal: 18),
      );
      expect(stats.remainingPlanned, 0);
    });

    test('wins over the projection from the slots', () {
      final SubjectStats stats = statsOf(
        of: subject(priorHeld: 10, priorAttended: 8, expectedTotal: 14),
        fromSlots: 30,
      );
      expect(stats.remainingPlanned, 4);
    });

    test('falls back to the slots when the subject does not say', () {
      final SubjectStats stats =
          statsOf(of: subject(priorHeld: 10, priorAttended: 8), fromSlots: 30);
      expect(stats.remainingPlanned, 30);
    });

    test('lets a subject with no classes at all be out of reach', () {
      final SubjectStats stats = statsOf(
        of: subject(priorHeld: 18, priorAttended: 6, expectedTotal: 20),
      );
      expect(stats.isUnrecoverable, isTrue);
      expect(stats.health, AttendanceHealth.lost);
    });
  });

  group('across every subject', () {
    OverallStats overall() {
      return OverallStats(
        subjects: <SubjectStats>[
          statsOf(
            of: subject(
                id: 1, priorHeld: 16, priorAttended: 14, expectedTotal: 18),
          ),
          statsOf(
            of: subject(
                id: 2,
                name: 'Maths',
                priorHeld: 7,
                priorAttended: 3,
                expectedTotal: 7),
            present: 1,
          ),
        ],
        target: 0.75,
      );
    }

    test('totals carry the balances, not just the marks', () {
      final OverallStats stats = overall();
      expect(stats.held, 24);
      expect(stats.attended, 18);
      expect(stats.percent, closeTo(75, 0.01));
    });

    test('the term figure counts what has not happened yet as missed', () {
      final OverallStats stats = overall();
      expect(stats.expectedTotal, 26);
      // Always the darker of the two, which is why it is shown beside the
      // headline rather than as it.
      expect(stats.termPercent, closeTo(69.23, 0.01));
      expect(stats.termPercent! < stats.percent, isTrue);
    });

    test('is silent about the term when no subject knows its total', () {
      final OverallStats stats = OverallStats(
        subjects: <SubjectStats>[statsOf(of: subject())],
        target: 0.75,
      );
      expect(stats.termPercent, isNull);
    });

    test('stays silent while any subject is still being projected', () {
      final OverallStats stats = OverallStats(
        subjects: <SubjectStats>[
          statsOf(of: subject(id: 1, priorHeld: 18, priorAttended: 12, expectedTotal: 20)),
          statsOf(of: subject(id: 2, name: 'Maths'), present: 1, fromSlots: 17),
        ],
        target: 0.75,
      );
      expect(stats.knowsTerm, isFalse);
      expect(stats.termPercent, isNull);
    });

    test('stays silent when the only total is the engine guessing', () {
      // The projection is about this app's own timetable, not the term.
      final OverallStats stats = OverallStats(
        subjects: <SubjectStats>[
          statsOf(of: subject(), present: 1, fromSlots: 17),
        ],
        target: 0.75,
      );
      expect(stats.knowsTerm, isFalse);
      expect(stats.termPercent, isNull);
    });
  });
}
