import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/notion/notion_client.dart';

final Uri _base = Uri.parse('https://notion.test');

String _error(String code) => jsonEncode(<String, String>{'code': code});

/// No gap by default: the pacing has its own test and every other one would
/// otherwise pay for it.
NotionClient _client(
  MockClient mock, {
  String? token = 'a-token',
  Future<bool> Function()? refresh,
  Duration gap = Duration.zero,
}) {
  return NotionClient(
    accessToken: () async => token,
    refresh: refresh ?? () async => false,
    httpClient: mock,
    baseUri: _base,
    minimumGap: gap,
  );
}

void main() {
  test('every call carries the token and the pinned version', () async {
    late http.BaseRequest sent;
    final NotionClient client = _client(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"object":"list"}', 200);
    }));

    final NotionResult result = await client.dataSource('ds-1');

    expect(sent.url, Uri.parse('https://notion.test/v1/data_sources/ds-1'));
    expect(sent.headers['Authorization'], 'Bearer a-token');
    expect(sent.headers['Notion-Version'], NotionClient.apiVersion);
    expect(result.ok, isTrue);
    expect(result.body, <String, Object?>{'object': 'list'});
  });

  test('a page parents on the data source, not the database', () async {
    late http.Request sent;
    final NotionClient client = _client(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"id":"page-1"}', 200);
    }));

    await client.createPage(
      dataSourceId: 'ds-1',
      properties: <String, Object?>{'Held': 1},
    );

    expect(sent.method, 'POST');
    expect(jsonDecode(sent.body), <String, Object?>{
      'parent': <String, String>{
        'type': 'data_source_id',
        'data_source_id': 'ds-1',
      },
      'properties': <String, Object?>{'Held': 1},
    });
  });

  test('a removed page is trashed, so the user can get it back', () async {
    late http.Request sent;
    final NotionClient client = _client(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"id":"page-1"}', 200);
    }));

    await client.trashPage('page-1');

    expect(sent.method, 'PATCH');
    expect(sent.url.path, '/v1/pages/page-1');
    expect(jsonDecode(sent.body), <String, Object?>{'in_trash': true});
  });

  test('an expired token is refreshed once and the call goes again', () async {
    int calls = 0;
    int refreshes = 0;
    final NotionClient client = _client(
      MockClient((http.Request r) async {
        calls++;
        return calls == 1
            ? http.Response(_error('unauthorized'), 401)
            : http.Response('{"results":[]}', 200);
      }),
      refresh: () async {
        refreshes++;
        return true;
      },
    );

    final NotionResult result = await client.queryDataSource('ds-1');

    expect(calls, 2);
    expect(refreshes, 1);
    expect(result.ok, isTrue);
  });

  test('a 401 that survives the refresh is not retried forever', () async {
    int calls = 0;
    int refreshes = 0;
    final NotionClient client = _client(
      MockClient((http.Request r) async {
        calls++;
        return http.Response(_error('unauthorized'), 401);
      }),
      refresh: () async {
        refreshes++;
        return true;
      },
    );

    final NotionResult result = await client.dataSource('ds-1');

    expect(calls, 2);
    expect(refreshes, 1);
    expect(result.failure, SyncFailure.auth);
  });

  test('a connection that cannot refresh is finished, not retried', () async {
    int calls = 0;
    final NotionClient client = _client(
      MockClient((http.Request r) async {
        calls++;
        return http.Response(_error('unauthorized'), 401);
      }),
      refresh: () async => false,
    );

    final NotionResult result = await client.dataSource('ds-1');

    expect(calls, 1);
    expect(result.failure, SyncFailure.auth);
  });

  test('a missing capability is not treated as an expired token', () async {
    int refreshes = 0;
    final NotionClient client = _client(
      MockClient(
        (http.Request r) async =>
            http.Response(_error('restricted_resource'), 403),
      ),
      refresh: () async {
        refreshes++;
        return true;
      },
    );

    final NotionResult result = await client.dataSource('ds-1');

    expect(refreshes, 0);
    expect(result.failure, SyncFailure.auth);
    expect(result.message, 'restricted_resource');
  });

  test('a page that is already gone is told apart from a bad request',
      () async {
    final NotionClient client = _client(
      MockClient(
        (http.Request r) async => http.Response(_error('object_not_found'), 404),
      ),
    );

    final NotionResult result = await client.trashPage('page-1');

    // The target reads this to call an archive done rather than retrying a
    // page nobody can reach any more.
    expect(result.failure, SyncFailure.rejected);
    expect(result.message, 'object_not_found');
  });

  test('the rate limit is reported rather than absorbed', () async {
    final NotionClient client = _client(
      MockClient(
        (http.Request r) async => http.Response(_error('rate_limited'), 429),
      ),
    );

    final NotionResult result = await client.searchDataSources();

    expect(result.failure, SyncFailure.rateLimited);
  });

  test('the caller drives paging, so the cursor passes through both ways',
      () async {
    late http.Request sent;
    final NotionClient client = _client(MockClient((http.Request r) async {
      sent = r;
      return http.Response(
        '{"results":[],"has_more":true,"next_cursor":"cur-2"}',
        200,
      );
    }));

    final NotionResult result = await client.searchDataSources(cursor: 'cur-1');

    expect(jsonDecode(sent.body), <String, Object?>{
      'filter': <String, String>{
        'value': 'data_source',
        'property': 'object',
      },
      'start_cursor': 'cur-1',
    });
    expect(result.body!['next_cursor'], 'cur-2');
  });

  test('requests are spaced so a large push does not rate-limit itself',
      () async {
    final List<DateTime> sentAt = <DateTime>[];
    final NotionClient client = _client(
      MockClient((http.Request r) async {
        sentAt.add(DateTime.now());
        return http.Response('{"id":"page-1"}', 200);
      }),
      gap: const Duration(milliseconds: 40),
    );

    await Future.wait<NotionResult>(<Future<NotionResult>>[
      client.dataSource('ds-1'),
      client.dataSource('ds-2'),
      client.dataSource('ds-3'),
    ]);

    expect(sentAt, hasLength(3));
    // Two gaps' worth, less a little: a timer may fire a millisecond early,
    // and the claim being made is that the sends are spaced at all — without
    // the pacing they land together, microseconds apart.
    expect(
      sentAt[2].difference(sentAt[0]),
      greaterThanOrEqualTo(const Duration(milliseconds: 60)),
    );
  });

  test('retiring a database goes to the database route, not the page one',
      () async {
    // A database is not a page, and its id does not resolve under /v1/pages.
    final List<String> paths = <String>[];
    final List<Object?> bodies = <Object?>[];
    final NotionClient client = _client(MockClient((http.Request r) async {
      paths.add(r.url.path);
      bodies.add(jsonDecode(r.body));
      return http.Response('{"id":"db-1"}', 200);
    }));

    await client.renameDatabase('db-1', 'Zeolite Attendance (old)');
    await client.trashDatabase('db-1');

    expect(paths, <String>['/v1/databases/db-1', '/v1/databases/db-1']);
    expect(
      (bodies.first! as Map<String, Object?>)['title'],
      <Object?>[
        <String, Object?>{
          'text': <String, Object?>{'content': 'Zeolite Attendance (old)'},
        },
      ],
    );
    expect(bodies.last, <String, Object?>{'in_trash': true});
  });
}
