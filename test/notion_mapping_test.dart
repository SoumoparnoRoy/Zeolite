import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';

/// The schema the app's own template ships with, in the shape a data source
/// reports it.
Map<String, Object?> _template() => <String, Object?>{
      'Name': <String, Object?>{'id': 'title', 'type': 'title'},
      'Course': <String, Object?>{
        'id': 'p1',
        'type': 'select',
        'select': <String, Object?>{'options': <Object?>[]},
      },
      'Date': <String, Object?>{'id': 'p2', 'type': 'date'},
      'Status': <String, Object?>{
        'id': 'p3',
        'type': 'select',
        'select': <String, Object?>{
          'options': <Object?>[
            <String, Object?>{'name': 'Present'},
            <String, Object?>{'name': 'Absent'},
            <String, Object?>{'name': 'Cancelled'},
            <String, Object?>{'name': 'Proxy'},
          ],
        },
      },
      'Type': <String, Object?>{
        'id': 'p4',
        'type': 'select',
        'select': <String, Object?>{
          'options': <Object?>[
            <String, Object?>{'name': 'Lecture'},
            <String, Object?>{'name': 'Practical'},
          ],
        },
      },
      'Held': <String, Object?>{'id': 'p5', 'type': 'number'},
      'Attendance Credit': <String, Object?>{'id': 'p6', 'type': 'number'},
      'Zeolite ID': <String, Object?>{'id': 'p7', 'type': 'rich_text'},
      'Time': <String, Object?>{'id': 'p8', 'type': 'rich_text'},
    };

List<NotionProperty> _properties(Map<String, Object?> schema) => <NotionProperty>[
      for (final MapEntry<String, Object?> e in schema.entries)
        NotionProperty.fromJson(e.key, e.value! as Map<String, Object?>),
    ];

NotionMapping _match(Map<String, Object?> schema) => NotionMapping.match(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Zeolite Attendance',
      properties: _properties(schema),
    );

void main() {
  test('the template it ships with maps with nothing left to correct', () {
    final NotionMapping mapping = _match(_template());

    expect(mapping.isComplete, isTrue);
    expect(mapping.fields.keys, containsAll(NotionField.values));
    expect(mapping.fields[NotionField.date]!.id, 'p2');
    expect(mapping.fields[NotionField.component]!.name, 'Name');
    // The column the CSV reader would refuse, because it wants a `/` in the
    // name to tell a counter from a yes/no flag.
    expect(mapping.fields[NotionField.held]!.id, 'p5');
    // Without this one a page cannot be recognised on the way back.
    expect(mapping.fields[NotionField.key]!.id, 'p7');
    // `Time` must not be mistaken for the title, which `Name` holds.
    expect(mapping.fields[NotionField.time]!.id, 'p8');
    expect(mapping.fields[NotionField.component]!.id, 'title');
  });

  test('status words pair with options spelled the same way', () {
    final NotionMapping mapping = _match(_template());

    expect(mapping.statusValues, <String, String>{
      'present': 'Present',
      'absent': 'Absent',
      'cancelled': 'Cancelled',
      'proxy': 'Proxy',
    });
  });

  test('a workspace with its own words is left for the user to answer', () {
    final Map<String, Object?> schema = _template();
    schema['Status'] = <String, Object?>{
      'id': 'p3',
      'type': 'select',
      'select': <String, Object?>{
        'options': <Object?>[
          <String, Object?>{'name': 'Attended'},
          <String, Object?>{'name': 'Missed'},
        ],
      },
    };

    final NotionMapping mapping = _match(schema);

    // Guessing that "Attended" means present is exactly the invention that
    // would file attendance wrongly and never say so.
    expect(mapping.statusValues, isEmpty);
    expect(mapping.fields[NotionField.status]!.id, 'p3');
  });

  test('a column that cannot hold the value is not offered for it', () {
    final Map<String, Object?> schema = _template();
    schema['Date'] = <String, Object?>{'id': 'p2', 'type': 'rich_text'};

    final NotionMapping mapping = _match(schema);

    // Mapping it anyway would read fine here and fail validation on every
    // row ever pushed.
    expect(mapping.fields.containsKey(NotionField.date), isFalse);
    expect(mapping.isComplete, isFalse);
  });

  test('one column cannot stand for two fields', () {
    final NotionMapping mapping = NotionMapping.match(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Attendance',
      properties: const <NotionProperty>[
        NotionProperty(id: 'p1', name: 'Held', type: 'number'),
      ],
    );

    expect(mapping.fields[NotionField.held]?.id, 'p1');
    expect(mapping.fields.containsKey(NotionField.credit), isFalse);
  });

  test('a database missing an optional column still counts as mapped', () {
    final Map<String, Object?> schema = _template()
      ..remove('Held')
      ..remove('Attendance Credit')
      ..remove('Type');

    expect(_match(schema).isComplete, isTrue);
  });

  test('a category pairs with a type option spelled the same way', () {
    final NotionMapping mapping = NotionMapping.match(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Attendance',
      properties: _properties(_template()),
      categoryNames: const <String>['Practical', 'Seminar'],
    );

    // `Seminar` is not an option here, and inventing one for it would file
    // classes under a type the workspace does not use.
    expect(mapping.kindValues, <String, String>{'practical': 'Practical'});
  });

  test('a stored mapping comes back the same, ids included', () {
    final NotionMapping mapping = _match(_template());

    final NotionMapping? back = NotionMapping.fromJson(mapping.toJson());

    expect(back, isNotNull);
    expect(back!.dataSourceId, 'ds-1');
    expect(back.title, 'Zeolite Attendance');
    expect(back.statusValues, mapping.statusValues);
    expect(back.kindValues, mapping.kindValues);
    expect(
      <NotionField, String>{
        for (final MapEntry<NotionField, NotionProperty> e
            in back.fields.entries)
          e.key: e.value.id,
      },
      <NotionField, String>{
        for (final MapEntry<NotionField, NotionProperty> e
            in mapping.fields.entries)
          e.key: e.value.id,
      },
    );
  });

  test('a mapping with no data source is treated as none at all', () {
    expect(NotionMapping.fromJson(<String, Object?>{'title': 'x'}), isNull);
  });
}
