import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/attendance_stats.dart';

/// Marks dated outside the semester used to be dropped from every figure on
/// the stats screen without a word, which cost a full debugging round. These
/// pin what the screen now has to say about them.
final DateTime _start = DateTime(2026, 8, 18);
final DateTime _end = DateTime(2026, 12, 16);

final AppSettings _term =
    AppSettings(semesterStart: _start, semesterEnd: _end);

AttendanceRecord _on(DateTime date) => AttendanceRecord(
      subjectId: 1,
      date: date,
      startMinutes: 540,
      status: AttendanceStatus.present,
    );

void main() {
  test('only the marks outside the window are gathered, with their span', () {
    final OutOfTermMarks marks = OutOfTermMarks.from(
      <AttendanceRecord>[
        _on(DateTime(2026, 8, 4)),
        _on(DateTime(2026, 7, 30)),
        _on(_start),
        _on(DateTime(2026, 12, 20)),
      ],
      _term,
    );

    expect(marks.count, 3);
    expect(marks.earliest, DateTime(2026, 7, 30));
    expect(marks.latest, DateTime(2026, 12, 20));
  });

  test('they stay counted as strays even once they count towards the figures',
      () {
    final List<AttendanceRecord> records = <AttendanceRecord>[
      _on(DateTime(2026, 8, 4)),
    ];
    final OutOfTermMarks marks = OutOfTermMarks.from(
      records,
      _term.copyWith(countOutsideTerm: true),
    );

    // Otherwise turning counting on would silently retract the very notice
    // that offered it, and there would be no way back.
    expect(marks.count, 1);
  });

  test('with no semester set nothing is outside it', () {
    final OutOfTermMarks marks = OutOfTermMarks.from(
      <AttendanceRecord>[_on(DateTime(1999, 1, 1))],
      const AppSettings(),
    );

    expect(marks.isEmpty, isTrue);
    expect(marks.widenedTerm(const AppSettings()), isNull);
  });

  group('widening', () {
    test('moves only the end that has marks beyond it', () {
      final OutOfTermMarks late = OutOfTermMarks.from(
        <AttendanceRecord>[_on(DateTime(2026, 12, 20))],
        _term,
      );

      expect(late.widenedTerm(_term), (_start, DateTime(2026, 12, 20)));
    });

    test('moves both when the marks straddle the term', () {
      final OutOfTermMarks both = OutOfTermMarks.from(
        <AttendanceRecord>[
          _on(DateTime(2026, 7, 30)),
          _on(DateTime(2026, 12, 20)),
        ],
        _term,
      );

      expect(
        both.widenedTerm(_term),
        (DateTime(2026, 7, 30), DateTime(2026, 12, 20)),
      );
    });

    test('never shrinks the term', () {
      final OutOfTermMarks early = OutOfTermMarks.from(
        <AttendanceRecord>[_on(DateTime(2026, 8, 4))],
        _term,
      );
      final (DateTime, DateTime) widened = early.widenedTerm(_term)!;

      expect(widened.$1.isBefore(_start), isTrue);
      expect(widened.$2, _end);
    });
  });
}
