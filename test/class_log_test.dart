import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/domain/class_log.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/notion_export.dart';
import 'package:zeolite/services/class_log_mapping_store.dart';

final DateTime _today = DateTime(2026, 9, 24);

ClassLogTable _table(List<String> lines) => ClassLogTable.of(
      Uint8List.fromList(utf8.encode(lines.join('\n'))),
    )!;

void main() {
  final ClassLogTable spanish = _table(<String>[
    'Asignatura,Fecha,Estado,Tipo',
    'Termodinámica,13/08/2026,Presente,Teoría',
    'Termodinámica,14/08/2026,Ausente,Teoría',
    'Termodinámica,15/08/2026,Médico,Laboratorio',
  ]);

  test('a file in its own words is asked about, then read through the answers',
      () {
    final ClassLogMapping guessed = ClassLogMapping.guess(spanish);
    expect(guessed.readyFor(spanish), isFalse);

    final ClassLogMapping answered = guessed.copyWith(
      columns: <NotionField, int>{
        NotionField.course: 0,
        NotionField.date: 1,
        NotionField.status: 2,
        NotionField.kind: 3,
      },
      statuses: <String, LogVerdict>{
        'presente': LogVerdict.present,
        'ausente': LogVerdict.absent,
        'médico': LogVerdict.absentTagged,
      },
    ).withGuessedWords(spanish);
    expect(answered.readyFor(spanish), isTrue);
    // 13/08 cannot be month first, so nobody is asked.
    expect(answered.dayFirst, isTrue);

    final List<NotionRow> rows =
        readClassLog(spanish, answered, today: _today).rows;
    expect(rows.map((NotionRow r) => r.date), <DateTime>[
      DateTime(2026, 8, 13),
      DateTime(2026, 8, 14),
      DateTime(2026, 8, 15),
    ]);
    // Any word beyond the three marks rides on one, in the file's spelling.
    expect(rows.last.status, AttendanceStatus.absent);
    expect(rows.last.tagName, 'Médico');
    expect(rows.last.kind, NotionKind.practical);
    expect(rows.last.kindLabel, 'Laboratorio');
  });

  test('dates that fit either order wait for an answer', () {
    final ClassLogTable table = _table(<String>[
      'Course,Date,Status',
      'Thermodynamics,05/08/2026,Present',
    ]);
    final ClassLogMapping guessed = ClassLogMapping.guess(table);

    expect(guessed.dayFirst, isNull);
    expect(guessed.readyFor(table), isFalse);
    expect(
      readClassLog(table, guessed.copyWith(dayFirst: false), today: _today)
          .rows
          .single
          .date,
      DateTime(2026, 5, 8),
    );
  });

  test('a template export needs no questions', () {
    final ClassLogTable table = _table(<String>[
      'Name,Attendance Credit (1/2/0),Course,Date,Held (1/2/0),Held?,L/T/P,'
          'Status',
      'ABC101L,1,Thermodynamics,Aug 5,1,Yes,Lecture,Proxy',
    ]);
    final ClassLogMapping guessed = ClassLogMapping.guess(table);

    expect(guessed.readyFor(table), isTrue);
    expect(
      readClassLog(table, guessed, today: _today).rows.single.tagName,
      'Proxy',
    );
  });

  test('a layout answered once is found again for the next file', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final ClassLogMappingStore store = ClassLogMappingStore();
    final ClassLogMapping answered = ClassLogMapping.guess(spanish).copyWith(
      columns: <NotionField, int>{
        NotionField.course: 0,
        NotionField.date: 1,
        NotionField.status: 2,
      },
      statuses: <String, LogVerdict>{
        'presente': LogVerdict.present,
        'ausente': LogVerdict.absent,
        'médico': LogVerdict.absentTagged,
      },
    );
    await store.save(spanish, answered);

    final ClassLogTable nextMonth = _table(<String>[
      'Asignatura,Fecha,Estado,Tipo',
      'Termodinámica,17/09/2026,Presente,Teoría',
    ]);
    final ClassLogMapping? found = await store.load(nextMonth);

    expect(found!.withGuessedWords(nextMonth).readyFor(nextMonth), isTrue);
  });
}
