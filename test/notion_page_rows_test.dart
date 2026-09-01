import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/notion/notion_page_rows.dart';
import 'package:zeolite/domain/notion_export.dart';

NotionProperty _p(String id, String name, String type,
        [List<String> options = const <String>[]]) =>
    NotionProperty(id: id, name: name, type: type, options: options);

/// A database somebody keeps themselves: their own words for the statuses,
/// and a `Course` they type into a select rather than relate.
NotionMapping _mapping({
  String courseType = 'select',
  Map<String, String>? statusValues,
  Map<String, String> kindValues = const <String, String>{},
  bool withKey = true,
  bool withTime = false,
}) =>
    NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Classes',
      fields: <NotionField, NotionProperty>{
        NotionField.course: _p('p1', 'Course', courseType),
        NotionField.date: _p('p2', 'Date', 'date'),
        NotionField.status: _p('p3', 'Status', 'select'),
        NotionField.component: _p('p4', 'Name', 'title'),
        NotionField.kind: _p('p5', 'Type', 'select'),
        NotionField.held: _p('p6', 'Held', 'number'),
        NotionField.credit: _p('p7', 'Attendance Credit', 'number'),
        if (withKey) NotionField.key: _p('p8', 'Zeolite ID', 'rich_text'),
        if (withTime) NotionField.time: _p('p9', 'Time', 'rich_text'),
      },
      statusValues: statusValues ??
          const <String, String>{
            'present': 'Present',
            'absent': 'Absent',
            'cancelled': 'Cancelled',
            'proxy': 'Proxy',
          },
      kindValues: kindValues,
    );

Map<String, Object?> _page({
  String? course = 'Generic Course',
  List<String> relatedTo = const <String>[],
  String? component = 'GEN101',
  String? date = '2026-03-04',
  String? status = 'Present',
  String? kind,
  num? held,
  num? credit,
  String? key,
  String? time,
}) =>
    <String, Object?>{
      'id': 'page-1',
      'properties': <String, Object?>{
        if (course != null)
          'Course': <String, Object?>{
            'id': 'p1',
            'select': <String, Object?>{'name': course},
          },
        if (relatedTo.isNotEmpty)
          'Course': <String, Object?>{
            'id': 'p1',
            'relation': <Object?>[
              for (final String id in relatedTo) <String, Object?>{'id': id},
            ],
          },
        if (date != null)
          'Date': <String, Object?>{
            'id': 'p2',
            'date': <String, Object?>{'start': date},
          },
        if (status != null)
          'Status': <String, Object?>{
            'id': 'p3',
            'select': <String, Object?>{'name': status},
          },
        if (component != null)
          'Name': <String, Object?>{
            'id': 'p4',
            'title': <Object?>[
              <String, Object?>{'plain_text': component},
            ],
          },
        if (kind != null)
          'Type': <String, Object?>{
            'id': 'p5',
            'select': <String, Object?>{'name': kind},
          },
        if (held != null) 'Held': <String, Object?>{'id': 'p6', 'number': held},
        if (credit != null)
          'Attendance Credit': <String, Object?>{'id': 'p7', 'number': credit},
        if (key != null)
          'Zeolite ID': <String, Object?>{
            'id': 'p8',
            'rich_text': <Object?>[
              <String, Object?>{'plain_text': key},
            ],
          },
        if (time != null)
          'Time': <String, Object?>{
            'id': 'p9',
            'rich_text': <Object?>[
              <String, Object?>{'plain_text': time},
            ],
          },
      },
    };

void main() {
  test('a row becomes a class under the mapped columns', () {
    final NotionExport export = NotionPageRows(_mapping()).read(
      <Map<String, Object?>>[_page(kind: 'Practical', held: 2, credit: 2)],
    );

    expect(export.problems, isEmpty);
    final NotionRow row = export.rows.single;
    expect(row.course, 'Generic Course');
    expect(row.component, 'GEN101');
    expect(row.date, DateTime(2026, 3, 4));
    expect(row.status, AttendanceStatus.present);
    expect(row.kind, NotionKind.practical);
    expect(row.weight, 2);
  });

  test("the workspace's own status words read back as ours", () {
    final NotionPageRows rows = NotionPageRows(
      _mapping(statusValues: const <String, String>{
        'present': 'Attended',
        'absent': 'Missed',
      }),
    );

    final NotionExport export = rows.read(<Map<String, Object?>>[
      _page(status: 'Attended'),
      _page(status: 'Missed'),
      _page(status: 'Rescheduled'),
    ]);

    expect(
      export.rows.map((NotionRow r) => r.status),
      <AttendanceStatus>[AttendanceStatus.present, AttendanceStatus.absent],
    );
    expect(export.problems.single, contains('"Rescheduled"'));
  });

  test('the credit column decides, and disagreement is reported', () {
    final NotionExport export = NotionPageRows(_mapping()).read(
      <Map<String, Object?>>[
        _page(status: 'Absent', held: 1, credit: 1),
        _page(status: 'Present', held: 0, credit: 0),
        _page(status: 'Proxy', held: 1, credit: 1),
      ],
    );

    expect(export.rows[0].status, AttendanceStatus.present);
    expect(export.rows[0].creditDisagrees, isTrue);
    // Held of zero is the class that never happened, whatever the word says.
    expect(export.rows[1].status, AttendanceStatus.cancelled);
    expect(export.rows[2].tagName, 'Proxy');
  });

  test('a related course is named from the pages that were read', () {
    final NotionPageRows rows = NotionPageRows(_mapping(courseType: 'relation'));
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[
      _page(course: null, relatedTo: <String>['course-a']),
      _page(course: null, relatedTo: <String>['course-b'], component: 'GEN202'),
    ];

    expect(rows.relatedCourseIds(pages), <String>{'course-a', 'course-b'});

    final NotionExport export = rows.read(
      pages,
      courseNames: const <String, String>{'course-a': 'Generic Course'},
    );

    expect(export.rows.single.course, 'Generic Course');
    // The one whose page would not load is said out loud, not dropped.
    expect(export.problems.single, contains('GEN202'));
  });

  test('a Type option the user paired with a category reads as that kind', () {
    final NotionExport export = NotionPageRows(
      _mapping(kindValues: const <String, String>{'lab': 'Session B'}),
    ).read(<Map<String, Object?>>[_page(kind: 'Session B')]);

    expect(export.rows.single.kind, NotionKind.practical);
  });

  test('an unreadable date is reported rather than dropped', () {
    final NotionExport export = NotionPageRows(_mapping())
        .read(<Map<String, Object?>>[_page(date: null), _page()]);

    expect(export.rows, hasLength(1));
    expect(export.problems.single, contains('no date'));
  });

  test('rows this device wrote can be left out, and are counted', () {
    final NotionPageRows rows = NotionPageRows(_mapping());
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[
      _page(key: 'uuid:20260304:540'),
      _page(),
    ];

    expect(rows.hasKeyed(pages), isTrue);
    expect(rows.read(pages).rows, hasLength(2));

    final NotionExport mine = rows.read(pages, skipKeyed: true);
    expect(mine.rows, hasLength(1));
    expect(mine.problems.single, contains('1 row already synced'));
  });

  test('nothing is keyed when the database has no ID column', () {
    final NotionPageRows rows = NotionPageRows(_mapping(withKey: false));
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[
      _page(key: 'uuid:20260304:540'),
    ];

    expect(rows.hasKeyed(pages), isFalse);
    expect(rows.read(pages, skipKeyed: true).rows, hasLength(1));
  });

  group('the optional Time column', () {
    test('is read as minutes past midnight', () {
      final NotionExport export = NotionPageRows(_mapping(withTime: true))
          .read(<Map<String, Object?>>[_page(time: '14:20')]);

      expect(export.problems, isEmpty);
      expect(export.rows.single.startMinutes, 14 * 60 + 20);
    });

    test('a row with no time this can read is placed by the importer instead',
        () {
      // Not a problem to report: the column is optional.
      for (final String? text in <String?>[null, 'after lunch', '99:99']) {
        final NotionExport export = NotionPageRows(_mapping(withTime: true))
            .read(<Map<String, Object?>>[_page(time: text)]);
        expect(export.problems, isEmpty, reason: text);
        expect(export.rows.single.startMinutes, isNull, reason: text);
      }
    });
  });
}
