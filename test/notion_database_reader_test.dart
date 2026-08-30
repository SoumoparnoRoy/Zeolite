import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/notion_export.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/notion/notion_client.dart';
import 'package:zeolite/services/notion/notion_database_reader.dart';

NotionProperty _p(String id, String name, String type) =>
    NotionProperty(id: id, name: name, type: type);

NotionMapping _mapping({String courseType = 'select'}) => NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Classes',
      fields: <NotionField, NotionProperty>{
        NotionField.course: _p('p1', 'Course', courseType),
        NotionField.date: _p('p2', 'Date', 'date'),
        NotionField.status: _p('p3', 'Status', 'select'),
      },
      statusValues: const <String, String>{
        'present': 'Present',
        'absent': 'Absent',
      },
    );

NotionDatabaseReader _reader(MockClient mock, {String courseType = 'select'}) =>
    NotionDatabaseReader(
      client: NotionClient(
        accessToken: () async => 'a-token',
        refresh: () async => false,
        httpClient: mock,
        baseUri: Uri.parse('https://notion.test'),
        minimumGap: Duration.zero,
      ),
      mapping: _mapping(courseType: courseType),
    );

Map<String, Object?> _row(String course) => <String, Object?>{
      'id': 'page-$course',
      'properties': <String, Object?>{
        'Course': <String, Object?>{
          'id': 'p1',
          'select': <String, Object?>{'name': course},
        },
        'Date': <String, Object?>{
          'id': 'p2',
          'date': <String, Object?>{'start': '2026-03-04'},
        },
        'Status': <String, Object?>{
          'id': 'p3',
          'select': <String, Object?>{'name': 'Present'},
        },
      },
    };

Map<String, Object?> _related(String id) => <String, Object?>{
      'id': 'page-$id',
      'properties': <String, Object?>{
        'Course': <String, Object?>{
          'id': 'p1',
          'relation': <Object?>[
            <String, Object?>{'id': id},
          ],
        },
        'Date': <String, Object?>{
          'id': 'p2',
          'date': <String, Object?>{'start': '2026-03-04'},
        },
        'Status': <String, Object?>{
          'id': 'p3',
          'select': <String, Object?>{'name': 'Present'},
        },
      },
    };

void main() {
  test('the walk follows the cursor to the end of the table', () async {
    int queries = 0;
    final NotionDatabaseReader reader = _reader(MockClient((_) async {
      queries++;
      final bool first = queries == 1;
      return http.Response(
        jsonEncode(<String, Object?>{
          'results': <Object?>[_row(first ? 'Course One' : 'Course Two')],
          'has_more': first,
          'next_cursor': first ? 'cursor-2' : null,
        }),
        200,
      );
    }));

    final NotionSource source = (await reader.read()).source!;

    expect(queries, 2);
    expect(source.length, 2);
    expect(
      source.read(skipKeyed: false).rows.map((NotionRow r) => r.course),
      <String>['Course One', 'Course Two'],
    );
  });

  test('a related course is read once however many rows point at it', () async {
    final List<String> paths = <String>[];
    final NotionDatabaseReader reader = _reader(
      MockClient((http.Request request) async {
        paths.add(request.url.path);
        if (request.url.path.startsWith('/v1/pages/')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'properties': <String, Object?>{
                'Name': <String, Object?>{
                  'type': 'title',
                  'title': <Object?>[
                    <String, Object?>{'plain_text': 'Generic Course'},
                  ],
                },
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object?>[_related('course-a'), _related('course-a')],
            'has_more': false,
          }),
          200,
        );
      }),
      courseType: 'relation',
    );

    final NotionSource source = (await reader.read()).source!;

    expect(
      paths.where((String p) => p.startsWith('/v1/pages/')),
      <String>['/v1/pages/course-a'],
    );
    expect(
      source.read(skipKeyed: false).rows.map((NotionRow r) => r.course),
      <String>['Generic Course', 'Generic Course'],
    );
  });

  test('a table that cannot be read gives back why', () async {
    final NotionDatabaseReader reader = _reader(
      MockClient((_) async => http.Response('{"code":"object_not_found"}', 404)),
    );

    final NotionReadResult result = await reader.read();

    expect(result.source, isNull);
    expect(result.failure, SyncFailure.rejected);
  });
}
