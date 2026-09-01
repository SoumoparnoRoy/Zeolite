import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/domain/notion/notion_course.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/notion/notion_client.dart';
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
}
