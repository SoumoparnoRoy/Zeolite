import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_stats.dart';

const Subject physics = Subject(id: 1, name: 'Physics', colorValue: 0xFF7C6BFF);

SubjectStats statsOf({
  int present = 0,
  int absent = 0,
  int cancelled = 0,
  double target = 0.75,
  int remaining = 0,
}) {
  return SubjectStats(
    subject: physics,
    present: present,
    absent: absent,
    cancelled: cancelled,
    target: target,
    plannedFromSlots: remaining,
  );
}

void main() {
  group('percentages', () {
    test('cancelled classes are excluded from both sides of the ratio', () {
      final SubjectStats stats = statsOf(present: 8, absent: 2, cancelled: 5);
      expect(stats.held, 10);
      expect(stats.percent, 80);
    });

    test('an unmarked subject reports no data rather than zero percent', () {
      final SubjectStats stats = statsOf();
      expect(stats.hasData, isFalse);
      expect(stats.health, AttendanceHealth.empty);
      // With nothing held, the target is vacuously met.
      expect(stats.meetsTarget, isTrue);
    });
  });

  group('skip allowance', () {
    test('says how many classes can still be missed', () {
      // 9/10 = 90%. Target 75% allows a total of floor(9/0.75) = 12 classes,
      // so two more may be missed.
      final SubjectStats stats = statsOf(present: 9, absent: 1);
      expect(stats.canSkip, 2);
    });

    test('is zero when sitting exactly on the target', () {
      final SubjectStats stats = statsOf(present: 3, absent: 1);
      expect(stats.percent, 75);
      expect(stats.meetsTarget, isTrue);
      expect(stats.canSkip, 0);
    });

    test('is zero when below the target', () {
      final SubjectStats stats = statsOf(present: 5, absent: 5);
      expect(stats.meetsTarget, isFalse);
      expect(stats.canSkip, 0);
    });

    test('skipping exactly the allowance keeps you on target', () {
      final SubjectStats stats = statsOf(present: 9, absent: 1);
      final SubjectStats after = statsOf(present: 9, absent: 1 + stats.canSkip);
      expect(after.meetsTarget, isTrue);

      final SubjectStats oneMore =
          statsOf(present: 9, absent: 2 + stats.canSkip);
      expect(oneMore.meetsTarget, isFalse);
    });
  });

  group('recovery', () {
    test('says how many classes must be attended in a row', () {
      // 5/10 = 50%. Need y where (5+y)/(10+y) >= 0.75 -> y >= 10.
      final SubjectStats stats = statsOf(present: 5, absent: 5);
      expect(stats.needToAttend, 10);
    });

    test('attending exactly that many reaches the target', () {
      final SubjectStats stats = statsOf(present: 5, absent: 5);
      final int need = stats.needToAttend;
      final SubjectStats after = statsOf(present: 5 + need, absent: 5);
      expect(after.meetsTarget, isTrue);

      final SubjectStats oneFewer = statsOf(present: 5 + need - 1, absent: 5);
      expect(oneFewer.meetsTarget, isFalse);
    });

    test('is zero when already on target', () {
      expect(statsOf(present: 8, absent: 2).needToAttend, 0);
    });
  });

  group('health', () {
    test('comfortably above target is safe', () {
      expect(statsOf(present: 20, absent: 1).health, AttendanceHealth.safe);
    });

    test('on the edge is tight', () {
      expect(statsOf(present: 3, absent: 1).health, AttendanceHealth.tight);
    });

    test('below target but recoverable is at risk', () {
      final SubjectStats stats = statsOf(present: 5, absent: 5, remaining: 30);
      expect(stats.health, AttendanceHealth.atRisk);
      expect(stats.isUnrecoverable, isFalse);
    });

    test('below target with too few classes left is lost', () {
      // 5/10 with only 2 classes left tops out at 7/12 = 58%.
      final SubjectStats stats = statsOf(present: 5, absent: 5, remaining: 2);
      expect(stats.health, AttendanceHealth.lost);
      expect(stats.isUnrecoverable, isTrue);
      expect(stats.maxAchievableRatio, closeTo(7 / 12, 1e-9));
    });
  });

  group('overall aggregation', () {
    test('sums across subjects and flags the weakest', () {
      final OverallStats overall = OverallStats(
        target: 0.75,
        subjects: <SubjectStats>[
          statsOf(present: 9, absent: 1),
          SubjectStats(
            subject: const Subject(
              id: 2,
              name: 'Maths',
              colorValue: 0xFF4FD6D2,
            ),
            present: 4,
            absent: 6,
            cancelled: 0,
            target: 0.75,
            plannedFromSlots: 20,
          ),
        ],
      );

      expect(overall.present, 13);
      expect(overall.absent, 7);
      expect(overall.held, 20);
      expect(overall.percent, 65);
      expect(overall.meetsTarget, isFalse);
      expect(overall.atRisk, hasLength(1));
      expect(overall.weakest?.subject.name, 'Maths');
    });

    test('reports no data when nothing has been marked', () {
      final OverallStats overall = OverallStats(
        target: 0.75,
        subjects: <SubjectStats>[statsOf()],
      );
      expect(overall.hasData, isFalse);
      expect(overall.weakest, isNull);
    });
  });

  group('the home screen verdict', () {
    test('counts spare classes from the tightest subject, not the average', () {
      // A healthy overall percentage says nothing about whether skipping the
      // next class is safe — the subject with the least room decides that.
      final OverallStats overall = OverallStats(
        subjects: <SubjectStats>[
          statsOf(present: 30, absent: 0),
          statsOf(present: 3, absent: 1),
        ],
        target: 0.75,
      );

      expect(overall.percent, greaterThan(90));
      expect(overall.canSkip, 0);
      expect(overall.verdict, 'None to spare');
    });

    test('ignores subjects with nothing marked', () {
      final OverallStats overall = OverallStats(
        subjects: <SubjectStats>[
          statsOf(present: 8, absent: 0),
          statsOf(),
        ],
        target: 0.75,
      );

      expect(overall.canSkip, 2);
      expect(overall.verdict, 'Two to spare');
    });

    test('sums the recovery runs when subjects are below target', () {
      final OverallStats overall = OverallStats(
        subjects: <SubjectStats>[
          statsOf(present: 2, absent: 2, remaining: 20),
          statsOf(present: 3, absent: 2, remaining: 20),
        ],
        target: 0.75,
      );

      expect(overall.needToAttend, 4 + 3);
      expect(overall.verdict, 'Seven to make up');
    });

    test('an unreachable target is reported as such', () {
      final OverallStats overall = OverallStats(
        subjects: <SubjectStats>[statsOf(present: 1, absent: 9, remaining: 1)],
        target: 0.75,
      );

      expect(overall.verdict, 'One out of reach');
    });

    test('says nothing rather than zero before anything is marked', () {
      const OverallStats overall =
          OverallStats(subjects: <SubjectStats>[], target: 0.75);
      expect(overall.verdict, 'Nothing marked yet');
    });
  });
}
