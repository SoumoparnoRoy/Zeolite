import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/domain/notion/notion_course.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/notion/notion_client.dart';
import 'package:zeolite/services/notion/notion_courses_writer.dart';
import 'package:zeolite/services/notion/notion_sync_target.dart';

const String _uuid = 'subject-uuid';
final String _key = '$_uuid:20260304:540';

NotionProperty _p(String id, String name, String type) =>
    NotionProperty(id: id, name: name, type: type);

/// The template's schema: `Course` is a relation into a Courses table.
NotionMapping _mapping() => NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Zeolite Attendance',
      fields: <NotionField, NotionProperty>{
        NotionField.course: _p('p1', 'Course', 'relation'),
        NotionField.date: _p('p2', 'Date', 'date'),
        NotionField.status: _p('p3', 'Status', 'select'),
        NotionField.key: _p('p7', 'Zeolite ID', 'rich_text'),
      },
      statusValues: const <String, String>{'present': 'Present'},
      courses: NotionCourses(
        databaseId: 'db-2',
        dataSourceId: 'ds-2',
        fields: <NotionCourseField, NotionProperty>{
          NotionCourseField.name: _p('c0', 'Name', 'title'),
          NotionCourseField.key: _p('c1', 'Zeolite ID', 'rich_text'),
          NotionCourseField.code: _p('c4', 'Code', 'rich_text'),
          NotionCourseField.priorHeld: _p('c2', 'Prior Held', 'number'),
          NotionCourseField.priorAttended:
              _p('c3', 'Prior Attended', 'number'),
        },
      ),
    );

SyncItem _mark() => SyncItem(
      kind: SyncKind.attendance,
      localKey: _key,
      fields: const <String, Object?>{'status': 'present', 'weight': 1},
      changedAt: DateTime(2026, 3, 4),
    );

NotionSyncTarget _target(MockClient mock, {NotionCourse? course}) =>
    NotionSyncTarget(
      client: NotionClient(
        accessToken: () async => 'a-token',
        refresh: () async => false,
        httpClient: mock,
        baseUri: Uri.parse('https://notion.test'),
        minimumGap: Duration.zero,
      ),
      mapping: _mapping(),
      course: (String uuid) =>
          course ??
          const NotionCourse(
            uuid: _uuid,
            name: 'Thermodynamics',
            code: 'SUB1',
            priorHeld: 6,
            priorAttended: 5,
          ),
    );

void main() {
  test('a subject with no page yet gets one, and the mark relates to it',
      () async {
    final List<Map<String, Object?>> created = <Map<String, Object?>>[];
    final MockClient client = MockClient((http.Request r) async {
      if (r.url.path == '/v1/data_sources/ds-2/query') {
        return http.Response('{"results":[],"has_more":false}', 200);
      }
      final Map<String, Object?> body =
          jsonDecode(r.body) as Map<String, Object?>;
      created.add(body);
      final String parent = ((body['parent']! as Map<String, Object?>)
          ['data_source_id'])! as String;
      return http.Response('{"id":"${parent == 'ds-2' ? 'course' : 'mark'}"}',
          200);
    });

    final SyncOutcome outcome = await _target(client).create(_mark());

    expect(outcome.remoteId, 'mark');
    expect(created, hasLength(2));

    // The course page comes first, because the mark cannot point at it
    // otherwise.
    final Map<String, Object?> coursePage =
        created.first['properties']! as Map<String, Object?>;
    expect(coursePage['c1'], <String, Object?>{
      'rich_text': <Object?>[
        <String, Object?>{
          'text': <String, Object?>{'content': _uuid},
        },
      ],
    });
    expect(coursePage['c4'], <String, Object?>{
      'rich_text': <Object?>[
        <String, Object?>{
          'text': <String, Object?>{'content': 'SUB1'},
        },
      ],
    });
    expect(coursePage['c2'], <String, Object?>{'number': 6});
    expect(coursePage['c3'], <String, Object?>{'number': 5});

    final Map<String, Object?> markPage =
        created.last['properties']! as Map<String, Object?>;
    expect(markPage['p1'], <String, Object?>{
      'relation': <Object?>[
        <String, Object?>{'id': 'course'},
      ],
    });
  });

  test('an existing page is reused rather than duplicated', () async {
    int coursePagesCreated = 0;
    final MockClient client = MockClient((http.Request r) async {
      if (r.url.path == '/v1/data_sources/ds-2/query') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'id': 'already-there',
                'properties': <String, Object?>{
                  'Zeolite ID': <String, Object?>{
                    'id': 'c1',
                    'rich_text': <Object?>[
                      <String, Object?>{'plain_text': _uuid},
                    ],
                  },
                  'Name': <String, Object?>{
                    'id': 'c0',
                    'title': <Object?>[
                      <String, Object?>{'plain_text': 'Thermodynamics'},
                    ],
                  },
                  'Prior Held': <String, Object?>{'id': 'c2', 'number': 6},
                  'Prior Attended': <String, Object?>{'id': 'c3', 'number': 5},
                },
              },
            ],
            'has_more': false,
          }),
          200,
        );
      }
      final Map<String, Object?> body =
          jsonDecode(r.body) as Map<String, Object?>;
      final Object? parent = body['parent'];
      if (parent is Map<String, Object?> &&
          parent['data_source_id'] == 'ds-2') {
        coursePagesCreated++;
      }
      return http.Response('{"id":"mark"}', 200);
    });

    final NotionSyncTarget target = _target(client);
    await target.create(_mark());
    await target.create(_mark());

    // Recognised by its Zeolite ID, exactly as a mark is.
    expect(coursePagesCreated, 0);
  });

  test('a course made by hand is taken over by name, keeping what he typed',
      () async {
    final List<String> writes = <String>[];
    final Map<String, Object?> patched = <String, Object?>{};
    final MockClient client = MockClient((http.Request r) async {
      writes.add('${r.method} ${r.url.path}');
      if (r.url.path == '/v1/data_sources/ds-2/query') {
        return http.Response(
          _coursePages(<Map<String, Object?>>[
            _coursePage('his-page', 'thermodynamics ', code: 'HIS1'),
          ]),
          200,
        );
      }
      if (r.method == 'PATCH') {
        patched.addAll((jsonDecode(r.body) as Map<String, Object?>)
            ['properties']! as Map<String, Object?>);
      }
      return http.Response('{"id":"mark"}', 200);
    });

    await _target(
      client,
      course: const NotionCourse(uuid: _uuid, name: 'Thermodynamics'),
    ).create(_mark());

    expect(writes.where((String w) => w == 'POST /v1/pages'), hasLength(1),
        reason: 'the only page made is the mark');
    expect(_textOf(patched['c1']), '${NotionCoursesWriter.adoptedMark}$_uuid');
    expect(_textOf(patched['c4']), 'HIS1');
  });

  test('a lab relates to the course it belongs to in a table kept by hand',
      () async {
    final List<Map<String, Object?>> created = <Map<String, Object?>>[];
    final MockClient client = MockClient((http.Request r) async {
      if (r.url.path == '/v1/data_sources/ds-2/query') {
        return http.Response(
          _coursePages(<Map<String, Object?>>[
            _coursePage('his-page', 'Thermodynamics'),
          ]),
          200,
        );
      }
      if (r.method == 'POST') {
        created.add(jsonDecode(r.body) as Map<String, Object?>);
      }
      return http.Response('{"id":"mark"}', 200);
    });

    await _target(
      client,
      course: const NotionCourse(uuid: _uuid, name: 'Thermodynamics Lab'),
    ).create(_mark());

    expect(created, hasLength(1), reason: 'no Lab course page is made');
    expect(
      (created.single['properties']! as Map<String, Object?>)['p1'],
      <String, Object?>{
        'relation': <Object?>[
          <String, Object?>{'id': 'his-page'},
        ],
      },
    );
  });

  test('two courses of one name are left alone, and the mark has no relation',
      () async {
    final List<Map<String, Object?>> created = <Map<String, Object?>>[];
    final MockClient client = MockClient((http.Request r) async {
      if (r.url.path == '/v1/data_sources/ds-2/query') {
        return http.Response(
          _coursePages(<Map<String, Object?>>[
            _coursePage('one', 'Thermodynamics'),
            _coursePage('two', 'Thermodynamics'),
          ]),
          200,
        );
      }
      if (r.method == 'POST') {
        created.add(jsonDecode(r.body) as Map<String, Object?>);
      }
      return http.Response('{"id":"mark"}', 200);
    });

    await _target(client).create(_mark());

    expect(created, hasLength(1));
    expect(
      (created.single['properties']! as Map<String, Object?>)
          .containsKey('p1'),
      isFalse,
    );
  });

  test('an update keeps a row on a course the table holds, and moves it off '
      'a trashed one', () async {
    final Map<String, Map<String, Object?>> rows =
        <String, Map<String, Object?>>{};
    final MockClient client = MockClient((http.Request r) async {
      if (r.url.path == '/v1/data_sources/ds-1/query') {
        return http.Response(
          _coursePages(<Map<String, Object?>>[
            _classRow('kept', relatedTo: 'his-page'),
            _classRow('orphaned', relatedTo: 'trashed-page'),
          ]),
          200,
        );
      }
      if (r.url.path == '/v1/data_sources/ds-2/query') {
        return http.Response(
          _coursePages(<Map<String, Object?>>[
            _coursePage('his-page', 'Thermodynamics'),
          ]),
          200,
        );
      }
      if (r.method == 'PATCH') {
        rows[r.url.pathSegments.last] = (jsonDecode(r.body)
            as Map<String, Object?>)['properties']! as Map<String, Object?>;
      }
      return http.Response('{"id":"row"}', 200);
    });

    final NotionSyncTarget target = _target(client);
    await target.fetch(SyncKind.attendance);
    await target.update(_mark(), 'kept');
    await target.update(_mark(), 'orphaned');

    expect(rows['kept']!.containsKey('p1'), isFalse);
    expect(rows['orphaned']!['p1'], <String, Object?>{
      'relation': <Object?>[
        <String, Object?>{'id': 'his-page'},
      ],
    });
  });
}

Map<String, Object?> _classRow(String id, {required String relatedTo}) =>
    <String, Object?>{
      'id': id,
      'properties': <String, Object?>{
        'Course': <String, Object?>{
          'id': 'p1',
          'relation': <Object?>[
            <String, Object?>{'id': relatedTo},
          ],
        },
        'Zeolite ID': <String, Object?>{
          'id': 'p7',
          'rich_text': <Object?>[
            <String, Object?>{'plain_text': '$id:20260304:540'},
          ],
        },
      },
    };

String _coursePages(List<Map<String, Object?>> pages) =>
    jsonEncode(<String, Object?>{'results': pages, 'has_more': false});

Map<String, Object?> _coursePage(String id, String name, {String? code}) =>
    <String, Object?>{
      'id': id,
      'properties': <String, Object?>{
        'Name': <String, Object?>{
          'id': 'c0',
          'title': <Object?>[
            <String, Object?>{'plain_text': name},
          ],
        },
        'Zeolite ID': <String, Object?>{'id': 'c1', 'rich_text': <Object?>[]},
        if (code != null)
          'Code': <String, Object?>{
            'id': 'c4',
            'rich_text': <Object?>[
              <String, Object?>{'plain_text': code},
            ],
          },
      },
    };

String? _textOf(Object? value) {
  final Object? parts = (value as Map<String, Object?>?)?['rich_text'];
  if (parts is! List<Object?> || parts.isEmpty) return null;
  return (((parts.first! as Map<String, Object?>)['text']!
      as Map<String, Object?>)['content']) as String?;
}
