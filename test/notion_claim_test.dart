import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/domain/notion/notion_claim.dart';
import 'package:zeolite/domain/notion/notion_page_rows.dart';
import 'package:zeolite/domain/notion_export.dart';
import 'package:zeolite/domain/sync/sync_target.dart';

const Map<String, String> _subjects = <String, String>{
  'uuid-theory': 'Generic Course',
  'uuid-lab': 'Generic Course Lab',
};

NotionUnkeyedRow _row(
  String pageId, {
  String course = 'Generic Course',
  NotionKind kind = NotionKind.lecture,
  int day = 4,
  AttendanceStatus status = AttendanceStatus.present,
  int? start,
}) =>
    NotionUnkeyedRow(
      pageId: pageId,
      row: NotionRow(
        component: '',
        course: course,
        kind: kind,
        date: DateTime(2026, 3, day),
        status: status,
        weight: 1,
        startMinutes: start,
      ),
    );

SyncItem _mark(String uuid, int start, {String status = 'present'}) =>
    SyncItem(
      kind: SyncKind.attendance,
      localKey: '$uuid:20260304:$start',
      fields: <String, Object?>{'status': status},
    );

Map<String, String> _pair(
  List<NotionUnkeyedRow> rows,
  List<SyncItem> marks, {
  Map<String, String> subjects = _subjects,
}) =>
    NotionClaim.pair(
      rows: rows,
      marks: marks,
      subjectName: (String uuid) => subjects[uuid],
    );

void main() {
  test('classes with no time pair with rows in the order they came in', () {
    final Map<String, String> paired = _pair(
      <NotionUnkeyedRow>[_row('first'), _row('second')],
      <SyncItem>[
        _mark('uuid-theory', AttendanceRecord.untimed(2)),
        _mark('uuid-theory', AttendanceRecord.untimed(1)),
      ],
    );

    expect(paired, <String, String>{
      'uuid-theory:20260304:-1': 'first',
      'uuid-theory:20260304:-2': 'second',
    });
  });

  test('a row pairs with its subject and day, and nothing else', () {
    final Map<String, String> paired = _pair(
      <NotionUnkeyedRow>[
        _row('same-day'),
        _row('other-day', day: 5),
        _row('other-course', course: 'Another Course'),
      ],
      <SyncItem>[_mark('uuid-theory', 540)],
    );

    // Another day and another course each leave the row alone.
    expect(paired, <String, String>{'uuid-theory:20260304:540': 'same-day'});
  });

  test('two classes on one day go by stated time, then by status', () {
    final Map<String, String> byTime = _pair(
      <NotionUnkeyedRow>[_row('ten', start: 600), _row('nine', start: 540)],
      <SyncItem>[_mark('uuid-theory', 540), _mark('uuid-theory', 600)],
    );
    final Map<String, String> byStatus = _pair(
      <NotionUnkeyedRow>[
        _row('was-there'),
        _row('missed', status: AttendanceStatus.absent),
      ],
      <SyncItem>[
        _mark('uuid-theory', 540, status: 'absent'),
        _mark('uuid-theory', 600),
      ],
    );

    expect(byTime['uuid-theory:20260304:540'], 'nine');
    expect(byTime['uuid-theory:20260304:600'], 'ten');
    expect(byStatus['uuid-theory:20260304:540'], 'missed');
    expect(byStatus['uuid-theory:20260304:600'], 'was-there');
  });

  test('a practical finds its lab, or its course when it was grouped in', () {
    final NotionUnkeyedRow lab = _row('lab', kind: NotionKind.practical);

    final Map<String, String> separate = _pair(
      <NotionUnkeyedRow>[lab],
      <SyncItem>[_mark('uuid-theory', 540), _mark('uuid-lab', 600)],
    );
    final Map<String, String> grouped = _pair(
      <NotionUnkeyedRow>[lab],
      <SyncItem>[_mark('uuid-theory', 540)],
      subjects: const <String, String>{'uuid-theory': 'Generic Course'},
    );

    expect(separate, <String, String>{'uuid-lab:20260304:600': 'lab'});
    expect(grouped, <String, String>{'uuid-theory:20260304:540': 'lab'});
  });
}
