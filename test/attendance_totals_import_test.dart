import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_totals_import.dart';
import 'package:zeolite/domain/attendance_totals_ocr.dart';

TotalsRow _row(String name, {int total = 18, int held = 16, int attended = 14}) {
  return TotalsRow(
    subject: name,
    expectedTotal: total,
    held: held,
    attended: attended,
  );
}

const Subject _signals = Subject(
  id: 1,
  name: 'Signal Theory',
  colorValue: 0xFF7C6BFF,
);

void main() {
  group('resolving a row against what is stored', () {
    test('an unknown course would be created', () {
      final TotalsPlan plan = TotalsPlan.from(
        rows: <TotalsRow>[_row('Control Systems')],
        subjects: const <Subject>[_signals],
        marksBySubject: const <int, int>{},
      );
      expect(plan.rows.single.match, TotalsMatch.create);
      expect(plan.rows.single.current, isNull);
    });

    test('a known course with nothing marked is a plain update', () {
      final TotalsPlan plan = TotalsPlan.from(
        rows: <TotalsRow>[_row('Signal Theory')],
        subjects: const <Subject>[_signals],
        marksBySubject: const <int, int>{},
      );
      expect(plan.rows.single.match, TotalsMatch.update);
    });

    test('the name match ignores case and stray spacing', () {
      final TotalsPlan plan = TotalsPlan.from(
        rows: <TotalsRow>[_row('  signal theory ')],
        subjects: const <Subject>[_signals],
        marksBySubject: const <int, int>{},
      );
      expect(plan.rows.single.subject?.id, 1);
    });

    test('a course already being marked here is an overlap, not an update',
        () {
      final TotalsPlan plan = TotalsPlan.from(
        rows: <TotalsRow>[_row('Signal Theory')],
        subjects: const <Subject>[_signals],
        marksBySubject: const <int, int>{1: 3},
      );
      expect(plan.rows.single.match, TotalsMatch.overlap);
      expect(plan.overlaps, hasLength(1));
    });

    test('shows what the subject reads today, marks included', () {
      const Subject carrying = Subject(
        id: 1,
        name: 'Signal Theory',
        colorValue: 0xFF7C6BFF,
        priorHeld: 10,
        priorAttended: 8,
      );
      final TotalsPlan plan = TotalsPlan.from(
        rows: <TotalsRow>[_row('Signal Theory')],
        subjects: const <Subject>[carrying],
        marksBySubject: const <int, int>{1: 2},
      );
      expect(plan.rows.single.current, '8 of 12');
    });
  });

  group('counting a whole page', () {
    TotalsPlan plan() => TotalsPlan.from(
          rows: <TotalsRow>[
            _row('Signal Theory'),
            _row('Control Systems'),
            _row('Imaging Lab'),
          ],
          subjects: const <Subject>[
            _signals,
            Subject(id: 2, name: 'Control Systems', colorValue: 0xFF7C6BFF),
          ],
          marksBySubject: const <int, int>{2: 5},
        );

    test('splits into what is created, updated and in conflict', () {
      expect(plan().countOf(TotalsMatch.create), 1);
      expect(plan().countOf(TotalsMatch.update), 1);
      expect(plan().countOf(TotalsMatch.overlap), 1);
    });

    test('a row that contradicts its own percentage is listed as suspect', () {
      final TotalsPlan p = TotalsPlan.from(
        rows: <TotalsRow>[
          const TotalsRow(
            subject: 'Signal Theory',
            expectedTotal: 18,
            held: 18,
            attended: 14,
            printedPercent: 87.5,
          ),
          _row('Control Systems'),
        ],
        subjects: const <Subject>[],
        marksBySubject: const <int, int>{},
      );
      expect(p.suspect, hasLength(1));
      expect(p.suspect.single.row.subject, 'Signal Theory');
    });
  });
}
