import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/services/notion/notion_client.dart';
import 'package:zeolite/services/notion/notion_template_retirement.dart';

NotionClient _client(MockClient http) => NotionClient(
      accessToken: () async => 'a-token',
      refresh: () async => false,
      httpClient: http,
      minimumGap: Duration.zero,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('finding the page a template arrived in', () {
    test('the id the mapping recorded is used without asking Notion',
        () async {
      int calls = 0;
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        calls++;
        return http.Response('{}', 200);
      })));

      expect(
        await retirement.pageOf(databaseId: 'db-1', knownPageId: 'page-1'),
        'page-1',
      );
      expect(calls, 0);
    });

    test('an older connection falls back to the database\'s parent', () async {
      // Connections made before the page was stored still have to retire the
      // whole template, and Notion knows who the parent is.
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        expect(r.url.path, '/v1/databases/db-1');
        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 'db-1',
            'parent': <String, Object?>{
              'type': 'page_id',
              'page_id': 'page-1',
            },
          }),
          200,
        );
      })));

      expect(await retirement.pageOf(databaseId: 'db-1'), 'page-1');
    });

    test('an inline database reports its block, and that block is the page',
        () async {
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        if (r.url.path == '/v1/databases/db-1') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'is_inline': true,
              'parent': <String, Object?>{
                'type': 'block_id',
                'block_id': 'page-1',
              },
            }),
            200,
          );
        }
        expect(r.url.path, '/v1/blocks/page-1');
        return http.Response('{"type":"child_page"}', 200);
      })));

      expect(await retirement.pageOf(databaseId: 'db-1'), 'page-1');
    });

    test('a database nested in a toggle keeps walking up to the page',
        () async {
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        if (r.url.path == '/v1/databases/db-1') {
          return http.Response(
            '{"parent":{"type":"block_id","block_id":"toggle-1"}}',
            200,
          );
        }
        if (r.url.path == '/v1/blocks/toggle-1') {
          return http.Response(
            '{"type":"toggle","parent":{"type":"page_id","page_id":"page-1"}}',
            200,
          );
        }
        return http.Response('{}', 404);
      })));

      expect(await retirement.pageOf(databaseId: 'db-1'), 'page-1');
    });

    test('a chain that never reaches a page gives up rather than looping',
        () async {
      int calls = 0;
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        calls++;
        return http.Response(
          '{"type":"toggle","parent":{"type":"block_id","block_id":"b"}}',
          200,
        );
      })));

      expect(await retirement.pageOf(databaseId: 'db-1'), isNull);
      // One database read plus a bounded number of block reads.
      expect(calls, lessThanOrEqualTo(6));
    });

    test('a database sitting straight in the workspace has no page', () async {
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        return http.Response(
          '{"id":"db-1","parent":{"type":"workspace","workspace":true}}',
          200,
        );
      })));

      expect(await retirement.pageOf(databaseId: 'db-1'), isNull);
    });
  });

  group('renaming what the user moved off', () {
    test('the page is renamed, from its own name and not the one inside it',
        () async {
      final List<String> paths = <String>[];
      Map<String, Object?>? sent;

      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        paths.add('${r.method} ${r.url.path}');
        if (r.method == 'GET') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'properties': <String, Object?>{
                'title': <String, Object?>{
                  'type': 'title',
                  'title': <Object?>[
                    <String, Object?>{'plain_text': 'Zeolite Attendance'},
                  ],
                },
              },
            }),
            200,
          );
        }
        sent = jsonDecode(r.body) as Map<String, Object?>;
        return http.Response('{}', 200);
      })));

      final NotionRename renamed = await retirement.rename(
        databaseId: 'db-1',
        databaseTitle: 'Zeolite Classes',
        pageId: 'page-1',
      );

      expect(renamed.result.ok, isTrue);
      expect(renamed.title, 'Zeolite Attendance (old)');
      expect(paths, <String>['GET /v1/pages/page-1', 'PATCH /v1/pages/page-1']);

      final Object? properties = sent?['properties'];
      expect(properties, isA<Map<String, Object?>>());
      expect(
        ((properties! as Map<String, Object?>)['title']
            as Map<String, Object?>)['title'],
        <Object?>[
          <String, Object?>{
            'text': <String, Object?>{'content': 'Zeolite Attendance (old)'},
          },
        ],
      );
    });

    test('a page whose name cannot be read falls back to the table name',
        () async {
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        if (r.method == 'GET') return http.Response('{}', 200);
        return http.Response('{}', 200);
      })));

      final NotionRename renamed = await retirement.rename(
        databaseId: 'db-1',
        databaseTitle: 'Zeolite Classes',
        pageId: 'page-1',
      );

      expect(renamed.title, 'Zeolite Classes (old)');
    });

    test('with no page above it, the table itself is renamed', () async {
      final List<String> paths = <String>[];
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        paths.add('${r.method} ${r.url.path}');
        return http.Response('{}', 200);
      })));

      final NotionRename renamed = await retirement.rename(
        databaseId: 'db-1',
        databaseTitle: 'Zeolite Classes',
      );

      expect(renamed.title, 'Zeolite Classes (old)');
      expect(paths, <String>['PATCH /v1/databases/db-1']);
    });
  });

  group('trashing what the user moved off', () {
    test('the page goes, which takes both tables with it', () async {
      final List<String> trashed = <String>[];
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        trashed.add(r.url.path);
        return http.Response('{}', 200);
      })));

      final NotionResult result = await retirement.trash(
        databaseId: 'db-1',
        pageId: 'page-1',
        coursesDatabaseId: 'courses',
      );

      expect(result.ok, isTrue);
      // One call, and to the page: the tables are inside it, so trashing them
      // separately would be both redundant and half-done if it failed.
      expect(trashed, <String>['/v1/pages/page-1']);
    });

    test('with no page above them, both tables are taken', () async {
      final List<String> trashed = <String>[];
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        trashed.add(r.url.path);
        return http.Response('{}', 200);
      })));

      await retirement.trash(
        databaseId: 'db-1',
        coursesDatabaseId: 'courses',
      );

      expect(
        trashed,
        <String>['/v1/databases/db-1', '/v1/databases/courses'],
      );
    });

    test('a failed attendance table leaves Courses alone', () async {
      // The marks are still only in the table that would not go.
      final List<String> trashed = <String>[];
      final NotionTemplateRetirement retirement =
          NotionTemplateRetirement(_client(MockClient((http.Request r) async {
        trashed.add(r.url.path);
        return http.Response(
          jsonEncode(<String, String>{'code': 'validation_error'}),
          400,
        );
      })));

      final NotionResult result = await retirement.trash(
        databaseId: 'db-1',
        coursesDatabaseId: 'courses',
      );

      expect(result.ok, isFalse);
      expect(trashed, <String>['/v1/databases/db-1']);
    });
  });
}
