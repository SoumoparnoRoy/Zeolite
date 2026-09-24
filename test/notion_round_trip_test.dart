import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/notion/notion_properties.dart';
import 'package:zeolite/domain/sync/sync_target.dart';

NotionProperty _p(String id, String name, String type) =>
    NotionProperty(id: id, name: name, type: type);

NotionMapping _mapping({String counters = 'number'}) => NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Zeolite Attendance',
      fields: <NotionField, NotionProperty>{
        NotionField.course: _p('p1', 'Course', 'select'),
        NotionField.date: _p('p2', 'Date', 'date'),
        NotionField.status: _p('p3', 'Status', 'select'),
        NotionField.held: _p('p5', 'Held', counters),
        NotionField.credit: _p('p6', 'Attendance Credit', counters),
        NotionField.key: _p('p7', 'Zeolite ID', 'rich_text'),
        NotionField.time: _p('p8', 'Time', 'rich_text'),
      },
      statusMeanings: const <String, LogVerdict>{
        'Present': LogVerdict.present,
        'Absent': LogVerdict.absent,
        'Cancelled': LogVerdict.cancelled,
        'Proxy': LogVerdict.presentTagged,
        'Medical': LogVerdict.absentTagged,
      },
    );

SyncItem _mark({required String status, int weight = 1, String? tag}) =>
    SyncItem(
      kind: SyncKind.attendance,
      localKey: 'subject-uuid:20260304:540',
      fields: <String, Object?>{
        'status': status,
        'weight': weight,
        if (tag != null) 'tag': tag,
      },
      changedAt: DateTime(2026, 3, 4),
    );

/// The page Notion would hold after [properties] were written to it: keyed by
/// name with the id inside, and rich text answered as `plain_text` rather than
/// the `text.content` it was written as.
Map<String, Object?> _pageFrom(Map<String, Object?> properties) {
  final Map<String, Object?> byName = <String, Object?>{};
  for (final MapEntry<NotionField, NotionProperty> field
      in _mapping().fields.entries) {
    final Object? written = properties[field.value.id];
    if (written is! Map<String, Object?>) continue;
    byName[field.value.name] = <String, Object?>{
      'id': field.value.id,
      for (final MapEntry<String, Object?> e in written.entries)
        e.key: e.key == 'rich_text' || e.key == 'title'
            ? _asRead(e.value)
            : e.value,
    };
  }
  return <String, Object?>{'id': 'page-1', 'properties': byName};
}

List<Object?> _asRead(Object? written) => <Object?>[
      for (final Object? part in (written as List<Object?>? ?? <Object?>[]))
        if (part is Map<String, Object?>)
          <String, Object?>{
            'plain_text':
                ((part['text'] as Map<String, Object?>?)?['content']) ?? '',
          },
    ];

void main() {
  final NotionProperties properties = NotionProperties(_mapping());

  test('what a push predicts is what a pull reads back', () {
    // These two have to agree or the far side reads as changed on every run
    // and the review offers a correction nobody made. A cancelled class broke
    // it once: `encode` wrote Held 0 while the prediction still said 1.
    for (final SyncItem item in <SyncItem>[
      _mark(status: 'present'),
      _mark(status: 'absent'),
      _mark(status: 'cancelled'),
      _mark(status: 'cancelled', weight: 2),
      _mark(status: 'present', weight: 2),
      _mark(status: 'present', tag: 'proxy'),
    ]) {
      final RemoteState? read = properties.decode(
        _pageFrom(properties.encode(item, courseName: 'Thermodynamics')),
      );

      expect(
        read?.hash,
        properties.remoteHashFor(item),
        reason: '${item.fields['status']} weight ${item.fields['weight']}',
      );
    }
  });

  test('a tagged option comes back as its status and tag', () {
    final SyncItem medical = _mark(status: 'absent', tag: 'Medical');
    final Map<String, Object?> written =
        properties.encode(medical, courseName: 'Thermodynamics');
    final RemoteState read = properties.decode(_pageFrom(written))!;

    expect(read.fields['status'], 'absent');
    expect(read.fields['tag'], 'Medical');
    expect(read.hash, properties.remoteHashFor(medical));

    // Online is not among the column's options, so the plain status is sent;
    // the options are the user's, not the app's to add to.
    final Map<String, Object?> online = properties.encode(
      _mark(status: 'present', tag: 'Online'),
      courseName: 'Thermodynamics',
    );
    expect(
      ((online['p3']! as Map<String, Object?>)['select']!
          as Map<String, Object?>)['name'],
      'Present',
    );
  });

  test('a Proxy row hashes as it did before options had meanings', () {
    // Rows linked under the old word-to-option mapping stored this hash;
    // anything else would push or review every Proxy row once.
    expect(
      properties.remoteHashFor(_mark(status: 'present', tag: 'Proxy')),
      const SyncItem(
        kind: SyncKind.attendance,
        localKey: 'subject-uuid:20260304:540',
        fields: <String, Object?>{'status': 'proxy', 'weight': 1},
      ).hash,
    );
  });

  test('formula counters are left alone and do not read as a change', () {
    final NotionProperties formulas =
        NotionProperties(_mapping(counters: 'formula'));
    final SyncItem item = _mark(status: 'present', weight: 2);
    final Map<String, Object?> written =
        formulas.encode(item, courseName: 'Thermodynamics');

    expect(written.containsKey('p5'), isFalse);
    expect(written.containsKey('p6'), isFalse);

    // The workspace works its own Held out, and it need not agree with ours.
    final Map<String, Object?> page = _pageFrom(written);
    (page['properties']! as Map<String, Object?>)['Held'] = <String, Object?>{
      'id': 'p5',
      'type': 'formula',
      'formula': <String, Object?>{'type': 'number', 'number': 1},
    };
    expect(formulas.decode(page)?.hash, formulas.remoteHashFor(item));
  });
}
