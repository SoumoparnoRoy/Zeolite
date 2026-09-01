import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/domain/notion/notion_course.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/notion/notion_client.dart';
import 'package:zeolite/services/notion/notion_sync_target.dart';

const String _uuid = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';
final String _key = '$_uuid:20260304:540';

NotionProperty _p(String id, String name, String type,
        [List<String> options = const <String>[]]) =>
    NotionProperty(id: id, name: name, type: type, options: options);

/// The schema the app's own template ships with.
NotionMapping _mapping({bool withKey = true}) => NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Attendance',
      fields: <NotionField, NotionProperty>{
        NotionField.course: _p('p1', 'Course', 'select'),
        NotionField.date: _p('p2', 'Date', 'date'),
        NotionField.status: _p('p3', 'Status', 'select',
            <String>['Present', 'Absent', 'Cancelled', 'Proxy']),
        NotionField.kind: _p('p4', 'Type', 'select',
            <String>['Lecture', 'Tutorial', 'Practical']),
        NotionField.held: _p('p5', 'Held', 'number'),
        NotionField.credit: _p('p6', 'Attendance Credit', 'number'),
        if (withKey) NotionField.key: _p('p7', 'Zeolite ID', 'rich_text'),
        NotionField.time: _p('p8', 'Time', 'rich_text'),
      },
      statusValues: const <String, String>{
        'present': 'Present',
        'absent': 'Absent',
        'cancelled': 'Cancelled',
        'proxy': 'Proxy',
      },
      kindValues: const <String, String>{'lab': 'Practical'},
    );

SyncItem _mark({
  String status = 'present',
  int weight = 1,
  String? tag,
}) =>
    SyncItem(
      kind: SyncKind.attendance,
      localKey: _key,
      fields: <String, Object?>{
        'status': status,
        'weight': weight,
        'note': null,
        'tag': tag,
      },
    );

NotionSyncTarget _target(
  MockClient mock, {
  bool withKey = true,
  String? category = 'Lab',
}) =>
    NotionSyncTarget(
      client: NotionClient(
        accessToken: () async => 'a-token',
        refresh: () async => false,
        httpClient: mock,
        baseUri: Uri.parse('https://notion.test'),
        minimumGap: Duration.zero,
      ),
      mapping: _mapping(withKey: withKey),
      course: (String uuid) => uuid == _uuid
          ? const NotionCourse(uuid: _uuid, name: 'Generic Course')
          : null,
      categoryName: (String uuid) => category,
    );

/// One page as Notion reports it back, in the shape the reader expects.
Map<String, Object?> _page({
  String id = 'page-1',
  String status = 'Present',
  int held = 1,
  String key = '',
}) =>
    <String, Object?>{
      'id': id,
      'last_edited_time': '2026-03-04T09:00:00.000Z',
      'properties': <String, Object?>{
        'Status': <String, Object?>{
          'id': 'p3',
          'select': <String, Object?>{'name': status},
        },
        'Held': <String, Object?>{'id': 'p5', 'number': held},
        'Zeolite ID': <String, Object?>{
          'id': 'p7',
          'rich_text': <Object?>[
            <String, Object?>{'plain_text': key.isEmpty ? _key : key},
          ],
        },
      },
    };

void main() {
  test('a mark becomes a page under the mapped columns', () async {
    late http.Request sent;
    final NotionSyncTarget target = _target(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"id":"page-9"}', 200);
    }));

    final SyncOutcome outcome = await target.create(_mark());

    final Map<String, Object?> body =
        jsonDecode(sent.body) as Map<String, Object?>;
    expect(body['parent'], <String, String>{
      'type': 'data_source_id',
      'data_source_id': 'ds-1',
    });
    final Map<String, Object?> props =
        body['properties']! as Map<String, Object?>;
    expect(props['p2'], <String, Object?>{
      'date': <String, Object?>{'start': '2026-03-04'},
    });
    expect(props['p1'], <String, Object?>{
      'select': <String, Object?>{'name': 'Generic Course'},
    });
    expect(props['p3'], <String, Object?>{
      'select': <String, Object?>{'name': 'Present'},
    });
    expect(props['p5'], <String, Object?>{'number': 1});
    expect(outcome.ok, isTrue);
    expect(outcome.remoteId, 'page-9');
  });

  test('the hash written after a push is the one the next read produces',
      () async {
    // Tagged on purpose: a plain mark hashes the same either way, because the
    // fields that differ between the two sides are the null ones a hash drops.
    final SyncItem mark = _mark(tag: 'Proxy', weight: 2);
    final NotionSyncTarget target = _target(
      MockClient((http.Request r) async {
        if (r.url.path.endsWith('/query')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'results': <Object?>[_page(status: 'Proxy', held: 2)],
              'has_more': false,
            }),
            200,
          );
        }
        return http.Response('{"id":"page-1"}', 200);
      }),
    );

    final SyncOutcome pushed = await target.create(mark);
    final List<RemoteState>? read = await target.fetch(SyncKind.attendance);

    // Any difference here and every row reads as changed in Notion on the
    // very next run, forever.
    expect(read, hasLength(1));
    expect(read!.single.hash, pushed.remoteHash);
    expect(read.single.localKey, _key);
  });

  test('a tag is what the workspace is told, not the status under it',
      () async {
    late http.Request sent;
    final NotionSyncTarget target = _target(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"id":"page-1"}', 200);
    }));

    await target.create(_mark(tag: 'Proxy'));

    final Map<String, Object?> props =
        (jsonDecode(sent.body) as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    // Writing "Present" would lose the distinction the user recorded, and the
    // export has always spelled this one out.
    expect(props['p3'], <String, Object?>{
      'select': <String, Object?>{'name': 'Proxy'},
    });
  });

  test('a class type is written as the workspace spells it', () async {
    late http.Request sent;
    final NotionSyncTarget target = _target(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"id":"page-1"}', 200);
    }));

    await target.create(_mark());

    final Map<String, Object?> props =
        (jsonDecode(sent.body) as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    // The category is `Lab` here and the option is `Practical`; the category
    // name itself is not a value this Type column offers.
    expect(props['p4'], <String, Object?>{
      'select': <String, Object?>{'name': 'Practical'},
    });
  });

  test('a category nobody has paired leaves the type alone', () async {
    late http.Request sent;
    final NotionSyncTarget target = _target(
      MockClient((http.Request r) async {
        sent = r;
        return http.Response('{"id":"page-1"}', 200);
      }),
      category: 'Seminar',
    );

    await target.create(_mark());

    final Map<String, Object?> props =
        (jsonDecode(sent.body) as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    expect(props.containsKey('p4'), isFalse);
  });

  test('an absence credits nothing, so the column cannot read as agreement',
      () async {
    late http.Request sent;
    final NotionSyncTarget target = _target(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"id":"page-1"}', 200);
    }));

    await target.create(_mark(status: 'absent', weight: 2));

    final Map<String, Object?> props =
        (jsonDecode(sent.body) as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    expect(props['p5'], <String, Object?>{'number': 2});
    expect(props['p6'], <String, Object?>{'number': 0});
  });

  test('a page nobody keyed is left to the import screen', () async {
    final NotionSyncTarget target = _target(
      MockClient(
        (http.Request r) async => http.Response(
          jsonEncode(<String, Object?>{
            'results': <Object?>[
              _page(),
              <String, Object?>{
                'id': 'page-2',
                'properties': <String, Object?>{
                  'Status': <String, Object?>{
                    'id': 'p3',
                    'select': <String, Object?>{'name': 'Present'},
                  },
                },
              },
            ],
            'has_more': false,
          }),
          200,
        ),
      ),
    );

    final List<RemoteState>? read = await target.fetch(SyncKind.attendance);

    // Adopting a hand-made row would file it against a class it may have
    // nothing to do with.
    expect(read, hasLength(1));
    expect(read!.single.remoteId, 'page-1');
  });

  test('a database with no key column reports itself unreadable', () async {
    int calls = 0;
    final NotionSyncTarget target = _target(
      MockClient((http.Request r) async {
        calls++;
        return http.Response('{"results":[],"has_more":false}', 200);
      }),
      withKey: false,
    );

    // Answering "empty" would tell the planner every linked page had gone and
    // drop the lot; null is read as a far side nobody could see.
    expect(await target.fetch(SyncKind.attendance), isNull);
    expect(calls, 0);
  });

  test('a page already gone counts the removal as done', () async {
    final NotionSyncTarget target = _target(
      MockClient(
        (http.Request r) async =>
            http.Response('{"code":"object_not_found"}', 404),
      ),
    );

    final SyncOutcome outcome =
        await target.archive(SyncKind.attendance, 'page-1');

    // Retrying forever would be the only thing that ever changed.
    expect(outcome.ok, isTrue);
  });

  test('Notion holds attendance and is never asked for anything else', () {
    final NotionSyncTarget target =
        _target(MockClient((http.Request r) async => http.Response('{}', 200)));

    expect(target.kinds, <SyncKind>{SyncKind.attendance});
    expect(target.trustsPulls, isFalse);
  });

  test('the start time is written as a plain 24-hour clock', () async {
    late http.Request sent;
    final NotionSyncTarget target = _target(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"id":"page-1"}', 200);
    }));

    await target.create(_mark());

    final Map<String, Object?> props =
        (jsonDecode(sent.body) as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    // 540 is the third part of the key. Written in its own column and never
    // onto the date, which Notion would treat as an instant and shift.
    expect(
      ((props['p8']! as Map<String, Object?>)['rich_text']! as List<Object?>)
          .single,
      <String, Object?>{
        'text': <String, Object?>{'content': '09:00'},
      },
    );
    expect(props['p2'], <String, Object?>{
      'date': <String, Object?>{'start': '2026-03-04'},
    });
  });

  test('a cancelled class is held zero times, not once', () async {
    late http.Request sent;
    final NotionSyncTarget target = _target(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"id":"page-1"}', 200);
    }));

    await target.create(_mark(status: 'cancelled', weight: 2));

    final Map<String, Object?> props =
        (jsonDecode(sent.body) as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    // The reader already treats held 0 as cancelled, and the dashboard sums
    // this column: held 2 would read as two classes you missed.
    expect(props['p5'], <String, Object?>{'number': 0});
    expect(props['p6'], <String, Object?>{'number': 0});
  });
}
