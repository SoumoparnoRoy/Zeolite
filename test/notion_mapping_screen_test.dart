import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/features/settings/notion_mapping_screen.dart';
import 'package:zeolite/services/notion/notion_auth_client.dart';
import 'package:zeolite/services/notion/notion_client.dart';
import 'package:zeolite/services/notion/notion_connection_store.dart';
import 'package:zeolite/state/notion_providers.dart';

Map<String, Object?> _select(String id, List<String> options) =>
    <String, Object?>{
      'id': id,
      'type': 'select',
      'select': <String, Object?>{
        'options': <Object?>[
          for (final String option in options)
            <String, Object?>{'name': option},
        ],
      },
    };

/// The schema the app's own template ships with.
Map<String, Object?> _schema() => <String, Object?>{
      'Name': <String, Object?>{'id': 'title', 'type': 'title'},
      'Course': _select('p1', <String>[]),
      'Date': <String, Object?>{'id': 'p2', 'type': 'date'},
      'Status': _select('p3', <String>['Present', 'Absent', 'Cancelled']),
      'Held': <String, Object?>{'id': 'p5', 'type': 'number'},
    };

/// Answers the two calls the screen makes. [tables] decides how many tables
/// the workspace shares.
MockClient _notion({
  Map<String, Object?>? schema,
  int tables = 1,
}) {
  return MockClient((http.Request request) async {
    final String path = request.url.path;
    if (path == '/v1/search') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'results': <Object?>[
            for (int i = 1; i <= tables; i++)
              <String, Object?>{
                'id': 'ds-$i',
                'title': <Object?>[
                  <String, Object?>{
                    'plain_text':
                        tables == 1 ? 'Zeolite Attendance' : 'Table $i',
                  },
                ],
                'parent': <String, Object?>{
                  'type': 'database_id',
                  'database_id': 'db-1',
                },
              },
          ],
          'has_more': false,
        }),
        200,
      );
    }
    if (path.startsWith('/v1/data_sources/')) {
      return http.Response(
        jsonEncode(<String, Object?>{'properties': schema ?? _schema()}),
        200,
      );
    }
    return http.Response('{}', 404);
  });
}

Widget _app(MockClient client) => ProviderScope(
      overrides: [
        notionClientProvider.overrideWithValue(
          NotionClient(
            accessToken: () async => 'a-token',
            refresh: () async => false,
            httpClient: client,
            baseUri: Uri.parse('https://notion.test'),
            minimumGap: Duration.zero,
          ),
        ),
        notionConnectionStoreProvider.overrideWithValue(
          NotionConnectionStore(storage: const FlutterSecureStorage()),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const NotionMappingScreen(),
      ),
    );

void main() {
  late Map<String, String> stored;

  setUp(() {
    stored = <String, String>{};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(stored);
  });

  testWidgets('picking a table goes straight to its columns',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_notion()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zeolite Attendance'));
    await tester.pumpAndSettle();

    expect(find.text('Course *'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('the guess is filled in and saved as the mapping',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_notion()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zeolite Attendance'));
    await tester.pumpAndSettle();

    final Finder save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final NotionMapping? saved =
        await NotionConnectionStore(storage: const FlutterSecureStorage())
            .readMapping();

    expect(saved, isNotNull);
    expect(saved!.dataSourceId, 'ds-1');
    expect(saved.title, 'Zeolite Attendance');
    expect(saved.fields[NotionField.date]!.id, 'p2');
    expect(saved.statusValues['present'], 'Present');
    // Absent from the schema, so it must not have been invented.
    expect(saved.statusValues.containsKey('proxy'), isFalse);
  });

  testWidgets('a database missing a date column cannot be saved',
      (WidgetTester tester) async {
    final Map<String, Object?> schema = _schema()..remove('Date');
    await tester.pumpWidget(_app(_notion(schema: schema)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zeolite Attendance'));
    await tester.pumpAndSettle();

    final FilledButton save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save'),
    );

    // Saving it would produce a mapping that fails on every row it pushes.
    expect(save.onPressed, isNull);
    expect(
      find.textContaining('needed before anything can be synced'),
      findsOneWidget,
    );
  });

  testWidgets('a column added since is offered without losing corrections',
      (WidgetTester tester) async {
    final NotionConnectionStore store =
        NotionConnectionStore(storage: const FlutterSecureStorage());
    // The mapping is only read for a live connection, so there has to be one.
    await store.write(const NotionTokens(accessToken: 'a-token'));

    // A mapping saved before the column existed, with a deliberate correction
    // in it that must survive.
    await store.writeMapping(NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Zeolite Attendance',
      fields: const <NotionField, NotionProperty>{
        NotionField.course: NotionProperty(
          id: 'title',
          name: 'Name',
          type: 'title',
        ),
      },
    ));

    await tester.pumpWidget(_app(_notion(schema: <String, Object?>{
      ..._schema(),
      'Zeolite ID': <String, Object?>{'id': 'p7', 'type': 'rich_text'},
    })));
    await tester.pumpAndSettle();

    final Finder save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final NotionMapping? saved =
        await NotionConnectionStore(storage: const FlutterSecureStorage())
            .readMapping();

    // The new column is picked up; the hand-made choice is not overwritten.
    expect(saved!.fields[NotionField.key]!.id, 'p7');
    expect(saved.fields[NotionField.course]!.id, 'title');
  });

  testWidgets('reopening keeps the pairings and the Courses table',
      (WidgetTester tester) async {
    final NotionConnectionStore store =
        NotionConnectionStore(storage: const FlutterSecureStorage());
    await store.write(const NotionTokens(accessToken: 'a-token'));

    await store.writeMapping(NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Zeolite Attendance',
      fields: const <NotionField, NotionProperty>{
        NotionField.kind:
            NotionProperty(id: 'p6', name: 'Type', type: 'select'),
      },
      // A pairing no guess would make: the words are nothing alike.
      kindValues: const <String, String>{'theory': 'Lecture'},
      courses: const NotionCourses(
        databaseId: 'db-2',
        dataSourceId: 'ds-2',
        fields: <NotionCourseField, NotionProperty>{
          NotionCourseField.name:
              NotionProperty(id: 'c0', name: 'Name', type: 'title'),
          NotionCourseField.key:
              NotionProperty(id: 'c1', name: 'Zeolite ID', type: 'rich_text'),
        },
      ),
    ));

    await tester.pumpWidget(_app(_notion(schema: <String, Object?>{
      ..._schema(),
      'Type': _select('p6', <String>['Lecture', 'Practical']),
    })));
    await tester.pumpAndSettle();

    final Finder save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final NotionMapping? saved =
        await NotionConnectionStore(storage: const FlutterSecureStorage())
            .readMapping();

    // The screen rebuilds the mapping from its own state, so anything it does
    // not read back is dropped on save — the pairing read as "Not used", and
    // the Courses table went silently.
    expect(saved!.kindValues, <String, String>{'theory': 'Lecture'});
    expect(saved.courses?.dataSourceId, 'ds-2');
  });

  testWidgets('every shared table is offered, not just the first',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(_notion(tables: 2)));
    await tester.pumpAndSettle();

    // Choosing for the user files attendance somewhere they never picked, and
    // nothing says so until they open Notion.
    expect(find.text('Table 1'), findsOneWidget);
    expect(find.text('Table 2'), findsOneWidget);
  });

  testWidgets('search asks for tables, which is what the API now answers',
      (WidgetTester tester) async {
    late Object? filter;
    await tester.pumpWidget(_app(MockClient((http.Request request) async {
      if (request.url.path == '/v1/search') {
        filter = (jsonDecode(request.body) as Map<String, Object?>)['filter'];
        return http.Response('{"results":[],"has_more":false}', 200);
      }
      return http.Response('{}', 404);
    })));
    await tester.pumpAndSettle();

    // `database` stopped being a value search takes, and asking for one is a
    // validation error rather than an empty list.
    expect(filter, <String, Object?>{
      'value': 'data_source',
      'property': 'object',
    });
  });
}
