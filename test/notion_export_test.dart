import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/domain/notion_export.dart';

const String _header =
    'Name,Attendance Credit (1/2/0),Course,Date,Held (1/2/0),Held?,L/T/P,'
    'Status';

const String _link = 'https://app.notion.com/p/x-1?pvs=21';

String _csv(List<String> rows) => <String>[_header, ...rows].join('\n');

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List _zip(Map<String, Uint8List> entries) {
  final Archive archive = Archive();
  for (final MapEntry<String, Uint8List> e in entries.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

final DateTime _today = DateTime(2026, 8, 26);

void main() {
  group('reading the rows', () {
    test('a lecture, a proxy and a two-period practical', () {
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>[
          'ABC101L,1,Thermodynamics ($_link),Jul 27,1,Yes,Lecture,Present',
          'ABC101L,1,Thermodynamics ($_link),Jul 28,1,Yes,Lecture,Proxy',
          'ABC101P,2,Thermodynamics ($_link),Aug 3,2,Yes,Practical,Present',
          'ABC101L,0,Thermodynamics ($_link),Aug 4,1,Yes,Lecture,Absent',
        ])),
        today: _today,
      );

      expect(export.problems, isEmpty);
      expect(export.rows.length, 4);

      // The relation cell carries a page link that is not part of the name.
      expect(export.rows.first.course, 'Thermodynamics');
      expect(export.rows.first.date, DateTime(2026, 7, 27));

      final NotionRow proxy = export.rows[1];
      expect(proxy.status, AttendanceStatus.present);
      expect(proxy.tagName, 'Proxy');

      final NotionRow practical = export.rows[2];
      expect(practical.kind, NotionKind.practical);
      expect(practical.weight, 2);

      expect(export.rows.last.status, AttendanceStatus.absent);
    });

    test('a credited cancelled class counts as attended, and says so', () {
      // This institution credits a cancelled class in full, and the portal's
      // own percentage only comes out right if it is counted.
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>[
          'ABC101L,1,Thermodynamics,Aug 5,1,Yes,Lecture,Cancelled',
        ])),
        today: _today,
      );
      final NotionRow row = export.rows.single;
      expect(row.status, AttendanceStatus.present);
      expect(row.tagName, 'Cancelled');
      expect(row.creditDisagrees, isFalse);
    });

    test('an uncredited cancelled class counts towards neither side', () {
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>[
          'ABC101L,0,Thermodynamics,Aug 5,1,Yes,Lecture,Cancelled',
        ])),
        today: _today,
      );
      // Not an absence: nobody was credited, so it is not held against you.
      expect(export.rows.single.status, AttendanceStatus.cancelled);
    });

    test('a class that never happened counts towards neither side', () {
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>[
          'ABC101L,0,Thermodynamics,Aug 5,0,No,Lecture,Present',
        ])),
        today: _today,
      );
      expect(export.rows.single.status, AttendanceStatus.cancelled);
    });

    test('the credit column wins when the word beside it disagrees', () {
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>[
          'ABC101L,0,Thermodynamics,Aug 5,1,Yes,Lecture,Present',
          'ABC101L,1,Thermodynamics,Aug 6,1,Yes,Lecture,Absent',
        ])),
        today: _today,
      );
      expect(export.rows[0].status, AttendanceStatus.absent);
      expect(export.rows[1].status, AttendanceStatus.present);
      // Still surfaced: a row contradicting itself is a typo in the sheet.
      expect(export.rows[0].creditDisagrees, isTrue);
      expect(export.rows[1].creditDisagrees, isTrue);
    });

    test('an unreadable row is reported rather than dropped in silence', () {
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>[
          'ABC101L,1,Thermodynamics,Aug 5,1,Yes,Lecture,Attended',
          'ABC101L,1,Thermodynamics,Smorgasbord 5,1,Yes,Lecture,Present',
          'ABC101L,1,Thermodynamics,Aug 7,1,Yes,Lecture,Present',
        ])),
        today: _today,
      );
      expect(export.rows.length, 1);
      expect(export.problems.length, 2);
      expect(export.problems.first, contains('Attended'));
      expect(export.problems.last, contains('not a date'));
    });
  });

  group('the year the export leaves off', () {
    test('a date already past this year stays in it', () {
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>['A,1,Course,Jul 27,1,Yes,Lecture,Present'])),
        today: _today,
      );
      expect(export.rows.single.date, DateTime(2026, 7, 27));
    });

    test('a date still to come this year belongs to the last one', () {
      // Read in January, a December row is last term rather than next.
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>['A,1,Course,Dec 3,1,Yes,Lecture,Present'])),
        today: DateTime(2026, 1, 12),
      );
      expect(export.rows.single.date, DateTime(2025, 12, 3));
    });

    test('a year printed in the cell wins', () {
      final NotionExport export = NotionExport.read(
        _bytes(_csv(<String>['A,1,Course,"Jul 27, 2024",1,Yes,Lecture,Present'])),
        today: _today,
      );
      expect(export.rows.single.date, DateTime(2024, 7, 27));
    });
  });

  group('the file it arrives in', () {
    final Uint8List csv = _bytes(_csv(<String>[
      'ABC101L,1,Thermodynamics,Aug 5,1,Yes,Lecture,Present',
    ]));

    test('a bare csv', () {
      expect(NotionExport.read(csv, today: _today).rows, hasLength(1));
    });

    test('a byte-order mark does not stick to the first header', () {
      final Uint8List marked = _bytes('﻿${utf8.decode(csv)}');
      expect(NotionExport.read(marked, today: _today).rows, hasLength(1));
    });

    test('the zip inside the zip Notion actually hands you', () {
      final Uint8List inner = _zip(<String, Uint8List>{'Classes abc.csv': csv});
      final Uint8List outer =
          _zip(<String, Uint8List>{'ExportBlock-1-Part-1.zip': inner});
      expect(NotionExport.read(outer, today: _today).rows, hasLength(1));
    });

    test('the _all csv wins, since the other one obeys the view filters', () {
      final Uint8List filtered = _bytes(_csv(<String>[
        'ABC101L,1,Thermodynamics,Aug 5,1,Yes,Lecture,Present',
      ]));
      final Uint8List all = _bytes(_csv(<String>[
        'ABC101L,1,Thermodynamics,Aug 5,1,Yes,Lecture,Present',
        'ABC101L,1,Thermodynamics,Aug 6,1,Yes,Lecture,Present',
      ]));
      final Uint8List zip = _zip(<String, Uint8List>{
        'Classes abc.csv': filtered,
        'Classes abc_all.csv': all,
      });
      expect(NotionExport.read(zip, today: _today).rows, hasLength(2));
    });

    test('something that is not an export says so', () {
      final NotionExport export =
          NotionExport.read(_bytes('nothing,useful\n1,2'), today: _today);
      expect(export.isEmpty, isTrue);
      expect(export.problems.single, contains('not a Notion class log'));
    });
  });

  group('the csv reader', () {
    test('a quoted cell keeps its commas and its doubled quotes', () {
      final List<List<String>> table =
          readCsv('a,"b,c","say ""hi""",d\n1,2,3,4');
      expect(table.first, <String>['a', 'b,c', 'say "hi"', 'd']);
      expect(table.last, <String>['1', '2', '3', '4']);
    });

    test('a newline inside a quoted cell does not end the row', () {
      final List<List<String>> table = readCsv('a,"one\ntwo",c');
      expect(table, hasLength(1));
      expect(table.first[1], 'one\ntwo');
    });

    test('a file that does not end in a newline keeps its last row', () {
      expect(readCsv('a,b\nc,d'), hasLength(2));
    });
  });
}
