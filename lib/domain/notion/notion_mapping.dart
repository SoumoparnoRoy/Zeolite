import 'package:flutter/foundation.dart';

/// A column on a Notion data source.
///
/// [id] is what calls are keyed on and [name] is only ever shown: Notion takes
/// either, but a column the user renames would silently stop matching a
/// name-keyed mapping and every push would fail validation with nothing
/// pointing at why.
@immutable
class NotionProperty {
  const NotionProperty({
    required this.id,
    required this.name,
    required this.type,
    this.options = const <String>[],
  });

  /// Reads one entry of a data source's `properties` map.
  factory NotionProperty.fromJson(String name, Map<String, Object?> json) {
    final String type = (json['type'] as String?) ?? '';
    return NotionProperty(
      id: (json['id'] as String?) ?? '',
      name: name,
      type: type,
      options: _optionsOf(type, json),
    );
  }

  final String id;
  final String name;
  final String type;

  /// The choices a select or status column offers, which are free text in
  /// every workspace and so have to be mapped rather than assumed.
  final List<String> options;

  static List<String> _optionsOf(String type, Map<String, Object?> json) {
    final Object? holder = json[type];
    if (holder is! Map<String, Object?>) return const <String>[];
    final Object? options = holder['options'];
    if (options is! List<Object?>) return const <String>[];
    return <String>[
      for (final Object? option in options)
        if (option is Map<String, Object?> && option['name'] is String)
          option['name']! as String,
    ];
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'type': type,
        if (options.isNotEmpty) 'options': options,
      };

  factory NotionProperty.restore(Map<String, Object?> json) => NotionProperty(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        type: (json['type'] as String?) ?? '',
        options: <String>[
          for (final Object? o in (json['options'] as List<Object?>?) ??
              const <Object?>[])
            if (o is String) o,
        ],
      );
}

/// What Zeolite needs a column for.
///
/// The three required ones are what a row cannot be read without; the rest
/// refine it, and a database that lacks them still syncs.
enum NotionField {
  course(
    label: 'Course',
    isRequired: true,
    types: <String>{'select', 'multi_select', 'rich_text', 'title', 'relation'},
  ),
  date(label: 'Date', isRequired: true, types: <String>{'date'}),
  status(label: 'Status', isRequired: true, types: <String>{'select', 'status'}),
  component(label: 'Component', types: <String>{'title', 'rich_text'}),
  kind(label: 'Type', types: <String>{'select'}),
  held(label: 'Held', types: <String>{'number'}),
  credit(label: 'Attendance Credit', types: <String>{'number'});

  const NotionField({
    required this.label,
    required this.types,
    this.isRequired = false,
  });

  final String label;

  /// Only a column that could hold the value is offered, or a mapping that
  /// reads fine fails validation on every row it ever pushes.
  final Set<String> types;

  final bool isRequired;

  /// Whether a column's name reads as this field.
  ///
  /// Loose on purpose — the point is to spare someone with their own database
  /// seven dropdowns, not to be clever. A wrong guess costs one correction on
  /// a screen they are already looking at.
  bool matches(String columnName) {
    final String n = columnName.trim().toLowerCase();
    return switch (this) {
      NotionField.course => n == 'course' || n == 'subject',
      NotionField.date => n == 'date',
      NotionField.status => n == 'status',
      NotionField.component => n == 'name' || n == 'component' || n == 'code',
      NotionField.kind => n == 'type' || n.contains('l/t/p'),
      // Plain `held` counts, unlike the CSV reader's rule: that one guards
      // against a database carrying both a `Held?` flag and a counter, which
      // is one real workspace rather than the shape this app authors.
      NotionField.held => n == 'held' || n.startsWith('held'),
      NotionField.credit => n.contains('credit'),
    };
  }
}

/// The status words a row can carry, as the importer already reads them.
///
/// Kept as strings rather than [AttendanceStatus] because two of them are
/// tags rather than statuses, and the far side only ever sees the word.
const List<String> kNotionStatusValues = <String>[
  'present',
  'absent',
  'cancelled',
  'proxy',
];

/// Which data source attendance is filed in, and which column holds what.
@immutable
class NotionMapping {
  const NotionMapping({
    required this.databaseId,
    required this.dataSourceId,
    required this.title,
    required this.fields,
    this.statusValues = const <String, String>{},
  });

  final String databaseId;

  /// Since 2025-09-03 the schema lives on the data source, not the database,
  /// and a database can hold more than one — so this is what a page parents on
  /// and what the mapping has to pin down.
  final String dataSourceId;

  /// Shown in Settings so the user can tell which database is being written
  /// to without opening Notion.
  final String title;

  final Map<NotionField, NotionProperty> fields;

  /// Zeolite's word to the workspace's own. Notion select options are free
  /// text, so `Present` here can be `Attended` there.
  final Map<String, String> statusValues;

  bool get isComplete => NotionField.values
      .where((NotionField f) => f.isRequired)
      .every(fields.containsKey);

  NotionMapping copyWith({
    String? dataSourceId,
    String? title,
    Map<NotionField, NotionProperty>? fields,
    Map<String, String>? statusValues,
  }) {
    return NotionMapping(
      databaseId: databaseId,
      dataSourceId: dataSourceId ?? this.dataSourceId,
      title: title ?? this.title,
      fields: fields ?? this.fields,
      statusValues: statusValues ?? this.statusValues,
    );
  }

  /// Fills what it can from a data source's schema.
  ///
  /// Every field is offered a column whose name reads right *and* whose type
  /// could hold it; anything ambiguous is simply left unset for the user.
  static NotionMapping match({
    required String databaseId,
    required String dataSourceId,
    required String title,
    required List<NotionProperty> properties,
  }) {
    final Map<NotionField, NotionProperty> fields =
        <NotionField, NotionProperty>{};
    final Set<String> taken = <String>{};

    for (final NotionField field in NotionField.values) {
      for (final NotionProperty property in properties) {
        if (taken.contains(property.id)) continue;
        if (!field.types.contains(property.type)) continue;
        if (!field.matches(property.name)) continue;
        fields[field] = property;
        taken.add(property.id);
        break;
      }
    }

    return NotionMapping(
      databaseId: databaseId,
      dataSourceId: dataSourceId,
      title: title,
      fields: fields,
      statusValues: _matchStatuses(fields[NotionField.status]),
    );
  }

  /// Pairs each word with an option spelled the same way. Anything else is
  /// left for the user, since a workspace calling it `Attended` is not
  /// something a guess should invent.
  static Map<String, String> _matchStatuses(NotionProperty? status) {
    if (status == null) return const <String, String>{};
    return <String, String>{
      for (final String word in kNotionStatusValues)
        for (final String option in status.options)
          if (option.trim().toLowerCase() == word) word: option,
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'databaseId': databaseId,
        'dataSourceId': dataSourceId,
        'title': title,
        'fields': <String, Object?>{
          for (final MapEntry<NotionField, NotionProperty> e in fields.entries)
            e.key.name: e.value.toJson(),
        },
        'statusValues': statusValues,
      };

  /// Null when what is stored no longer parses. Remapping is the recovery,
  /// and it is a screen the user can already reach.
  static NotionMapping? fromJson(Map<String, Object?> json) {
    final String? dataSourceId = json['dataSourceId'] as String?;
    if (dataSourceId == null || dataSourceId.isEmpty) return null;

    final Object? raw = json['fields'];
    final Map<NotionField, NotionProperty> fields =
        <NotionField, NotionProperty>{};
    if (raw is Map<String, Object?>) {
      for (final MapEntry<String, Object?> entry in raw.entries) {
        final NotionField? field = _fieldNamed(entry.key);
        final Object? value = entry.value;
        if (field == null || value is! Map<String, Object?>) continue;
        fields[field] = NotionProperty.restore(value);
      }
    }

    final Object? statuses = json['statusValues'];
    return NotionMapping(
      databaseId: (json['databaseId'] as String?) ?? '',
      dataSourceId: dataSourceId,
      title: (json['title'] as String?) ?? '',
      fields: fields,
      statusValues: <String, String>{
        if (statuses is Map<String, Object?>)
          for (final MapEntry<String, Object?> e in statuses.entries)
            if (e.value is String) e.key: e.value! as String,
      },
    );
  }

  static NotionField? _fieldNamed(String value) {
    for (final NotionField field in NotionField.values) {
      if (field.name == value) return field;
    }
    return null;
  }
}
