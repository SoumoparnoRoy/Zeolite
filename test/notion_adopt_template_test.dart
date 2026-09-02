import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/services/notion/notion_client.dart';
import 'package:zeolite/services/notion/notion_connection_store.dart';
import 'package:zeolite/state/notion_providers.dart';

String _error(String code) => jsonEncode(<String, String>{'code': code});

/// What Notion answers for the duplicated database once it is fully made.
const String _ready = '{"id":"db-1","data_sources":[{"id":"ds-1"}],'
    '"title":[{"plain_text":"Zeolite Attendance"}]}';

/// The same call while the copy is still being made: the database is there,
/// the table inside it is not.
const String _notYet = '{"id":"db-1","data_sources":[]}';

/// A Courses table: real, complete, and missing everything a mark needs.
String get _coursesSchema => jsonEncode(<String, Object?>{
      'properties': <String, Object?>{
        'Name': <String, Object?>{'id': 'title', 'type': 'title'},
        'Zeolite ID': <String, Object?>{'id': 'c0', 'type': 'rich_text'},
        'Prior Held': <String, Object?>{'id': 'c1', 'type': 'number'},
        'Prior Attended': <String, Object?>{'id': 'c2', 'type': 'number'},
      },
    });

String get _schema => jsonEncode(<String, Object?>{
      'properties': <String, Object?>{
        'Name': <String, Object?>{'id': 'title', 'type': 'title'},
        'Course': <String, Object?>{'id': 'p1', 'type': 'select'},
        'Date': <String, Object?>{'id': 'p2', 'type': 'date'},
        'Status': <String, Object?>{'id': 'p3', 'type': 'select'},
        'Zeolite ID': <String, Object?>{'id': 'p7', 'type': 'rich_text'},
      },
    });

ProviderContainer _container(MockClient http) => ProviderContainer(
      overrides: [
        notionConnectionStoreProvider.overrideWithValue(
          NotionConnectionStore(storage: const FlutterSecureStorage()),
        ),
        notionClientProvider.overrideWithValue(
          NotionClient(
            accessToken: () async => 'a-token',
            refresh: () async => false,
            httpClient: http,
            minimumGap: Duration.zero,
          ),
        ),
      ],
    );

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
  });

  test('a copy Notion has not finished making is waited for, not given up on',
      () async {
    int databaseCalls = 0;
    final MockClient client = MockClient((http.Request r) async {
      if (r.url.path.startsWith('/v1/databases/')) {
        databaseCalls++;
        // Empty twice, exactly as Notion answers straight after consent.
        return http.Response(databaseCalls > 2 ? _ready : _notYet, 200);
      }
      return http.Response(_schema, 200);
    });

    final ProviderContainer container = _container(client);
    addTearDown(container.dispose);
    await container.read(notionMappingProvider.future);

    final bool adopted = await container
        .read(notionMappingProvider.notifier)
        .adoptTemplate('db-1');

    expect(adopted, isTrue);
    expect(databaseCalls, 3);
    expect(container.read(notionMappingProvider).value?.isComplete, isTrue);
  });

  test('a template page hands over the database inside it', () async {
    // The relation only survives duplication when both databases are copied
    // together, so consent returns the page holding them, not a database.
    final MockClient client = MockClient((http.Request r) async {
      final String path = r.url.path;
      if (path == '/v1/databases/page-1') {
        return http.Response(_error('object_not_found'), 404);
      }
      if (path == '/v1/blocks/page-1/children') {
        return http.Response(
          '{"results":[{"id":"courses","type":"child_database"},'
          '{"id":"db-1","type":"child_database"},'
          '{"id":"blk","type":"paragraph"}]}',
          200,
        );
      }
      if (path == '/v1/databases/courses') {
        return http.Response('{"id":"courses","data_sources":'
            '[{"id":"ds-c"}],"title":[{"plain_text":"Zeolite Courses"}]}', 200);
      }
      if (path == '/v1/databases/db-1') return http.Response(_ready, 200);
      return http.Response(
        r.url.path.endsWith('ds-c') ? _coursesSchema : _schema,
        200,
      );
    });

    final ProviderContainer container = _container(client);
    addTearDown(container.dispose);
    await container.read(notionMappingProvider.future);

    expect(
      await container.read(notionMappingProvider.notifier).adoptTemplate('page-1'),
      isTrue,
    );
    // Courses comes first in the page and has no Date or Status, so it cannot
    // be mistaken for the table marks are filed in.
    final NotionMapping mapping = container.read(notionMappingProvider).value!;
    expect(mapping.databaseId, 'db-1');
    // And the sibling is kept, which is what the dashboard is rolled up from.
    expect(mapping.courses?.databaseId, 'courses');
    expect(mapping.courses?.isComplete, isTrue);
    expect(
      mapping.courses?.fields[NotionCourseField.priorAttended]?.id,
      'c2',
    );
  });

  test('a database inside a toggle heading is still found', () async {
    // Laying the template out with toggle headings makes each database a child
    // of its heading, not of the page.
    final MockClient client = MockClient((http.Request r) async {
      final String path = r.url.path;
      if (path == '/v1/databases/page-1') {
        return http.Response(_error('object_not_found'), 404);
      }
      if (path == '/v1/blocks/page-1/children') {
        return http.Response(
          '{"results":[{"id":"toggle","type":"heading_2",'
          '"has_children":true},{"id":"text","type":"paragraph"}]}',
          200,
        );
      }
      if (path == '/v1/blocks/toggle/children') {
        return http.Response(
          '{"results":[{"id":"db-1","type":"child_database"}]}',
          200,
        );
      }
      if (path == '/v1/databases/db-1') return http.Response(_ready, 200);
      return http.Response(_schema, 200);
    });

    final ProviderContainer container = _container(client);
    addTearDown(container.dispose);
    await container.read(notionMappingProvider.future);

    expect(
      await container.read(notionMappingProvider.notifier).adoptTemplate('page-1'),
      isTrue,
    );
    expect(container.read(notionMappingProvider).value?.databaseId, 'db-1');
  });

  test('a database renamed in Notion is picked up by the next run', () async {
    String name = 'Zeolite Attendance';
    final MockClient client = MockClient((http.Request r) async {
      if (r.url.path.startsWith('/v1/databases/')) {
        return http.Response(
          '{"id":"db-1","data_sources":[{"id":"ds-1"}],'
          '"title":[{"plain_text":"$name"}]}',
          200,
        );
      }
      return http.Response(_schema, 200);
    });

    final ProviderContainer container = _container(client);
    addTearDown(container.dispose);
    await container.read(notionMappingProvider.future);
    await container.read(notionMappingProvider.notifier).adoptTemplate('db-1');

    name = 'Zeolite Classes';
    await container.read(notionMappingProvider.notifier).refreshTitle();

    expect(container.read(notionMappingProvider).value?.title, 'Zeolite Classes');
    // Written through as well, or the old name is back on the next launch.
    final NotionConnectionStore store =
        container.read(notionConnectionStoreProvider);
    expect((await store.readMapping())?.title, 'Zeolite Classes');
  });

  test('a name that cannot be read leaves the stored one alone', () async {
    bool reachable = true;
    final MockClient client = MockClient((http.Request r) async {
      if (r.url.path.startsWith('/v1/databases/')) {
        return reachable
            ? http.Response(_ready, 200)
            : http.Response(_error('internal_server_error'), 500);
      }
      return http.Response(_schema, 200);
    });

    final ProviderContainer container = _container(client);
    addTearDown(container.dispose);
    await container.read(notionMappingProvider.future);
    await container.read(notionMappingProvider.notifier).adoptTemplate('db-1');

    reachable = false;
    await container.read(notionMappingProvider.notifier).refreshTitle();

    expect(
      container.read(notionMappingProvider).value?.title,
      'Zeolite Attendance',
    );
  });
}
