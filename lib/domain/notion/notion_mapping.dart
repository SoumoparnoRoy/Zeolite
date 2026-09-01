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

  /// The class's start time as plain `HH:mm`.
  ///
  /// Its own column rather than a time on [date], because Notion treats a
  /// datetime as an instant and shifts it by timezone; `09:00` has no instant
  /// to shift. Optional, and only an import of a database this app did not
  /// write actually needs it — see `NotionImport._place`.
  time(label: 'Time', types: <String>{'rich_text', 'select'}),
  kind(label: 'Type', types: <String>{'select'}),
  held(label: 'Held', types: <String>{'number'}),
  credit(label: 'Attendance Credit', types: <String>{'number'}),

  /// Holds `SyncItem.localKey` verbatim. Without it a page cannot be
  /// recognised again — Notion has no start time and no subject id, so two
  /// classes of the same course on one day are the same row — and syncing
  /// falls back to pushing without ever reading the far side.
  key(label: 'Zeolite ID', types: <String>{'rich_text'});

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
      NotionField.time => n == 'time' || n == 'start' || n == 'start time',
      NotionField.kind => n == 'type' || n.contains('l/t/p'),
      // Plain `held` counts, unlike the CSV reader's rule: that one guards
      // against a database carrying both a `Held?` flag and a counter, which
      // is one real workspace rather than the shape this app authors.
      NotionField.held => n == 'held' || n.startsWith('held'),
      NotionField.credit => n.contains('credit'),
      NotionField.key => n == 'zeolite id' || n == 'zeolite key',
    };
  }
}

/// What Zeolite needs a column for on the *Courses* table.
///
/// A second data source, holding one page per subject, so the workspace can
/// roll attendance up per course. Only [name] and [key] are needed: the prior
/// counts refine the dashboard and a table without them still works.
enum NotionCourseField {
  name(types: <String>{'title'}),
  key(types: <String>{'rich_text'}),
  priorHeld(types: <String>{'number'}),
  priorAttended(types: <String>{'number'});

  const NotionCourseField({required this.types});

  final Set<String> types;

  bool matches(String columnName) {
    final String n = columnName.trim().toLowerCase();
    return switch (this) {
      NotionCourseField.name => n == 'name' || n == 'course' || n == 'subject',
      NotionCourseField.key => n == 'zeolite id' || n == 'zeolite key',
      NotionCourseField.priorHeld => n == 'prior held',
      NotionCourseField.priorAttended => n == 'prior attended',
    };
  }
}

/// The Courses table a mark's `Course` relation points into.
///
/// Optional throughout: a workspace whose `Course` is a plain select has no
/// Courses table, and everything except the dashboard works without one.
@immutable
class NotionCourses {
  const NotionCourses({
    required this.databaseId,
    required this.dataSourceId,
    required this.fields,
  });

  final String databaseId;
  final String dataSourceId;
  final Map<NotionCourseField, NotionProperty> fields;

  /// A course page has to be findable again, and a title is the only thing a
  /// person reads. Without both there is nothing worth writing.
  bool get isComplete =>
      fields.containsKey(NotionCourseField.name) &&
      fields.containsKey(NotionCourseField.key);

  static NotionCourses match({
    required String databaseId,
    required String dataSourceId,
    required List<NotionProperty> properties,
  }) {
    final Map<NotionCourseField, NotionProperty> fields =
        <NotionCourseField, NotionProperty>{};
    final Set<String> taken = <String>{};
    for (final NotionCourseField field in NotionCourseField.values) {
      for (final NotionProperty property in properties) {
        if (taken.contains(property.id)) continue;
        if (!field.types.contains(property.type)) continue;
        if (!field.matches(property.name)) continue;
        fields[field] = property;
        taken.add(property.id);
        break;
      }
    }
    return NotionCourses(
      databaseId: databaseId,
      dataSourceId: dataSourceId,
      fields: fields,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'databaseId': databaseId,
        'dataSourceId': dataSourceId,
        'fields': <String, Object?>{
          for (final MapEntry<NotionCourseField, NotionProperty> e
              in fields.entries)
            e.key.name: e.value.toJson(),
        },
      };

  static NotionCourses? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final String? dataSourceId = raw['dataSourceId'] as String?;
    if (dataSourceId == null || dataSourceId.isEmpty) return null;

    final Map<NotionCourseField, NotionProperty> fields =
        <NotionCourseField, NotionProperty>{};
    final Object? stored = raw['fields'];
    if (stored is Map<String, Object?>) {
      for (final MapEntry<String, Object?> entry in stored.entries) {
        final Object? value = entry.value;
        if (value is! Map<String, Object?>) continue;
        for (final NotionCourseField field in NotionCourseField.values) {
          if (field.name == entry.key) {
            fields[field] = NotionProperty.restore(value);
          }
        }
      }
    }
    return NotionCourses(
      databaseId: (raw['databaseId'] as String?) ?? '',
      dataSourceId: dataSourceId,
      fields: fields,
    );
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
    this.courses,
    this.statusValues = const <String, String>{},
    this.kindValues = const <String, String>{},
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

  /// A class category here to a `Type` option there, keyed by the lowercased
  /// category name — `lab` to `Practical`.
  ///
  /// A category says what kind of session a subject holds, which is the only
  /// local thing `Type` describes; a tag says how one class went, and belongs
  /// in [statusValues] instead.
  final Map<String, String> kindValues;

  bool get isComplete => NotionField.values
      .where((NotionField f) => f.isRequired)
      .every(fields.containsKey);

  NotionMapping copyWith({
    String? dataSourceId,
    String? title,
    Map<NotionField, NotionProperty>? fields,
    Map<String, String>? statusValues,
    Map<String, String>? kindValues,
    NotionCourses? courses,
  }) {
    return NotionMapping(
      databaseId: databaseId,
      dataSourceId: dataSourceId ?? this.dataSourceId,
      title: title ?? this.title,
      fields: fields ?? this.fields,
      statusValues: statusValues ?? this.statusValues,
      kindValues: kindValues ?? this.kindValues,
      courses: courses ?? this.courses,
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
    List<String> categoryNames = const <String>[],
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
      statusValues: _pairByName(
        fields[NotionField.status],
        kNotionStatusValues,
      ),
      kindValues: _pairByName(fields[NotionField.kind], categoryNames),
    );
  }

  /// Pairs each of [words] with an option spelled the same way.
  ///
  /// Nothing else is paired: a workspace calling it `Attended`, or a `Lab`
  /// category against a `Practical` option, is a judgement only the user can
  /// make, and guessing it would file attendance under the wrong word.
  static Map<String, String> _pairByName(
    NotionProperty? property,
    List<String> words,
  ) {
    if (property == null) return const <String, String>{};
    return <String, String>{
      for (final String word in words)
        for (final String option in property.options)
          if (option.trim().toLowerCase() == word.trim().toLowerCase())
            word.trim().toLowerCase(): option,
    };
  }

  /// The Courses table this database's `Course` relation points into, or null
  /// when there is not one. Only the dashboard needs it.
  final NotionCourses? courses;

  Map<String, Object?> toJson() => <String, Object?>{
        'databaseId': databaseId,
        'dataSourceId': dataSourceId,
        'title': title,
        'fields': <String, Object?>{
          for (final MapEntry<NotionField, NotionProperty> e in fields.entries)
            e.key.name: e.value.toJson(),
        },
        'statusValues': statusValues,
        'kindValues': kindValues,
        if (courses != null) 'courses': courses!.toJson(),
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

    return NotionMapping(
      databaseId: (json['databaseId'] as String?) ?? '',
      dataSourceId: dataSourceId,
      title: (json['title'] as String?) ?? '',
      fields: fields,
      statusValues: _stringMap(json['statusValues']),
      kindValues: _stringMap(json['kindValues']),
      courses: NotionCourses.fromJson(json['courses']),
    );
  }

  static Map<String, String> _stringMap(Object? raw) => <String, String>{
        if (raw is Map<String, Object?>)
          for (final MapEntry<String, Object?> e in raw.entries)
            if (e.value is String) e.key: e.value! as String,
      };

  static NotionField? _fieldNamed(String value) {
    for (final NotionField field in NotionField.values) {
      if (field.name == value) return field;
    }
    return null;
  }
}
