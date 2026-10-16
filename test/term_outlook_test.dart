import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/domain/term_outlook.dart';

SubjectStats statsOf({
  int id = 1,
  int present = 0,
  int absent = 0,
  int cancelled = 0,
  double target = 0.75,
  int fromSlots = 0,
  int? termTotal,
  bool weighted = false,
  bool cancelledCounts = false,
}) {
  return SubjectStats(
    subject: Subject(
      id: id,
      name: 'Course $id',
      colorValue: 0xFF7C6BFF,
      expectedTotal: termTotal,
    ),
    present: present,
    absent: absent,
    cancelled: cancelled,
    target: target,
    plannedFromSlots: fromSlots,
    weighted: weighted,
    cancelledCounts: cancelledCounts,
  );
}

TermOutlook outlookOf(SubjectStats stats) =>
    TermOutlook.of(stats, termEndKnown: true)!;

void main() {
  test('the budget counts the classes to come, which canSkip does not', () {
    // 16 of 20 so far, 20 more in a 40-class term, 75% needed: the term can
    // lose six of what is left, though only one could go in a row from today.
    final SubjectStats stats = statsOf(present: 16, absent: 4, fromSlots: 20);
    final TermOutlook outlook = outlookOf(stats);

    expect(stats.canSkip, 1);
    expect(outlook.budget, 6);
    expect(outlook.line, 'Skip budget this term: 6 classes');
    expect(outlook.bestRatio, closeTo(0.9, 1e-9));
    expect(outlook.spentRatio, closeTo(0.75, 1e-9));
  });

  test('a subject that counts in periods says periods', () {
    final TermOutlook outlook = outlookOf(
      statsOf(present: 16, absent: 4, fromSlots: 20, weighted: true),
    );
    expect(outlook.line, 'Skip budget this term: 6 periods');
  });

  test('cancelled classes that count as attended widen the budget', () {
    // From the timetable, so what is left does not shrink as they count.
    final int off = outlookOf(
      statsOf(present: 12, absent: 4, cancelled: 4, fromSlots: 20),
    ).budget;
    final int on = outlookOf(statsOf(
      present: 12,
      absent: 4,
      cancelled: 4,
      fromSlots: 20,
      cancelledCounts: true,
    )).budget;
    expect(off, 5);
    expect(on, 6);
  });

  group('the edges', () {
    test('a 100% target leaves nothing to spare, and one miss loses it', () {
      final TermOutlook clean =
          outlookOf(statsOf(present: 10, target: 1, termTotal: 30));
      expect(clean.budget, 0);
      expect(clean.reachable, isTrue);
      expect(clean.line, 'Skip budget this term: none');

      final TermOutlook missed =
          outlookOf(statsOf(present: 9, absent: 1, target: 1, termTotal: 30));
      expect(missed.reachable, isFalse);
      expect(missed.line, 'Target is out of reach this term');
    });

    test('a term already over has nothing left to attend', () {
      final TermOutlook done =
          outlookOf(statsOf(present: 30, absent: 2, termTotal: 32));
      expect(done.remaining, 0);
      expect(done.line, 'No classes left this term');
      expect(done.health, AttendanceHealth.safe);
    });

    test('a subject that can no longer make it is out of reach', () {
      final TermOutlook lost =
          outlookOf(statsOf(present: 10, absent: 20, termTotal: 40));
      expect(lost.reachable, isFalse);
      expect(lost.budget, 0);
      expect(lost.health, AttendanceHealth.lost);
    });

    test('without an end date or a term total there is nothing to plan', () {
      final SubjectStats undated = statsOf(present: 16, absent: 4);
      expect(TermOutlook.of(undated, termEndKnown: false), isNull);

      final SubjectStats totalled =
          statsOf(present: 16, absent: 4, termTotal: 40);
      expect(TermOutlook.of(totalled, termEndKnown: false)?.budget, 6);
    });
  });

  test('the term plan puts the tightest first and never pools budgets', () {
    final TermPlan plan = TermPlan.of(
      OverallStats(
        target: 0.75,
        subjects: <SubjectStats>[
          statsOf(id: 1, present: 16, absent: 4, fromSlots: 20),
          statsOf(id: 2, present: 10, absent: 20, fromSlots: 10),
          statsOf(id: 3, present: 15, absent: 5, fromSlots: 20),
        ],
      ),
      termEndKnown: true,
    );

    expect(
      plan.subjects.map((TermOutlook o) => o.stats.subject.id),
      <int>[2, 3, 1],
    );
    // Course 2 cannot spend anything, so spending the other two budgets
    // leaves it attending all ten of its own: 41 + 50 - (6 + 5) of 120.
    final double spent = (41 + 50 - 11) * 100 / 120;
    expect(plan.spentPercent, closeTo(spent, 1e-9));
  });
}
