import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/notion/notion_properties.dart';
import 'package:zeolite/domain/sync/sync_target.dart';

NotionProperty _p(String id, String name, String type) =>
    NotionProperty(id: id, name: name, type: type);

NotionMapping _mapping() => NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Zeolite Attendance',
      fields: <NotionField, NotionProperty>{
        NotionField.course: _p('p1', 'Course', 'select'),
        NotionField.date: _p('p2', 'Date', 'date'),
        NotionField.status: _p('p3', 'Status', 'select'),
        NotionField.held: _p('p5', 'Held', 'number'),
        NotionField.credit: _p('p6', 'Attendance Credit', 'number'),
        NotionField.key: _p('p7', 'Zeolite ID', 'rich_text'),
        NotionField.time: _p('p8', 'Time', 'rich_text'),
      },
      statusValues: const <String, String>{
        'present': 'Present',
        'absent': 'Absent',
        'cancelled': 'Cancelled',
        'proxy': 'Proxy',
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
}
