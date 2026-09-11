import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/timetable_choices.dart';
import 'package:zeolite/domain/timetable_ocr.dart';

OcrEntry _at(String subject, {int weekday = 1, String? group}) => OcrEntry(
      subject: subject,
      weekday: weekday,
      from: 9 * 60,
      to: 10 * 60,
      group: group,
    );

void main() {
  group('choosing which of a sheet\'s alternatives are yours', () {
    test('nothing answered keeps every alternative', () {
      const TimetableChoices none =
          TimetableChoices(baskets: <ElectiveBasket>[]);
      expect(none.keeps(_at('AAA', group: 'B1')), isTrue);
      expect(none.keeps(_at('BBB', group: 'B2')), isTrue);
    });

    // The bug this screen exists to fix: B and G are separate questions, and
    // answering one used to comment out the other's classes.
    test('answering a batch leaves the group markers alone', () {
      const TimetableChoices mine = TimetableChoices(
        baskets: <ElectiveBasket>[],
        groups: <String>{'B1'},
      );
      expect(mine.keeps(_at('AAA', group: 'B1')), isTrue);
      expect(mine.keeps(_at('BBB', group: 'B2')), isFalse);
      expect(mine.keeps(_at('CCC', group: 'G2')), isTrue);
      expect(mine.keeps(_at('DDD', group: 'G3')), isTrue);
    });

    test('answering both axes narrows both', () {
      const TimetableChoices mine = TimetableChoices(
        baskets: <ElectiveBasket>[],
        groups: <String>{'B1', 'G2'},
      );
      expect(mine.keeps(_at('AAA', group: 'B1')), isTrue);
      expect(mine.keeps(_at('BBB', group: 'B2')), isFalse);
      expect(mine.keeps(_at('CCC', group: 'G2')), isTrue);
      expect(mine.keeps(_at('DDD', group: 'G3')), isFalse);
    });

    test('an ungrouped class survives any answer', () {
      const TimetableChoices mine = TimetableChoices(
        baskets: <ElectiveBasket>[],
        groups: <String>{'B1'},
      );
      expect(mine.keeps(_at('AAA')), isTrue);
    });

    group('elective baskets', () {
      const ElectiveBasket basket = ElectiveBasket(
        subjects: <String>['AAA', 'BBB', 'CCC'],
        slots: <(int, int, int)>[(1, 9 * 60, 10 * 60)],
      );

      test('an unanswered basket keeps all of its courses', () {
        const TimetableChoices mine =
            TimetableChoices(baskets: <ElectiveBasket>[basket]);
        expect(mine.keeps(_at('AAA')), isTrue);
        expect(mine.keeps(_at('BBB')), isTrue);
      });

      test('answering one keeps only that course', () {
        const TimetableChoices mine = TimetableChoices(
          baskets: <ElectiveBasket>[basket],
          electives: <int, String>{0: 'BBB'},
        );
        expect(mine.keeps(_at('BBB')), isTrue);
        expect(mine.keeps(_at('AAA')), isFalse);
        expect(mine.keeps(_at('CCC')), isFalse);
      });

      // Two baskets can offer the same course, so an answer must not reach
      // past the slots its own basket covers.
      test('an answer only applies to its own slots', () {
        const TimetableChoices mine = TimetableChoices(
          baskets: <ElectiveBasket>[basket],
          electives: <int, String>{0: 'BBB'},
        );
        expect(mine.keeps(_at('AAA', weekday: 5)), isTrue);
      });
    });
  });
}
