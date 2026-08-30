import '../../core/date_utils.dart';
import '../sync/sync_target.dart';
import 'notion_mapping.dart';

/// Turning a mark into Notion property values and reading one back.
///
/// Pure, and separate from the target that calls it: getting a property
/// envelope wrong fails every row of a push at once, so it is the part worth
/// being able to test without a network anywhere near it.
class NotionProperties {
  const NotionProperties(this.mapping);

  final NotionMapping mapping;

  /// What a page needs, keyed by property id.
  ///
  /// [courseName] comes from the caller because a mark carries its subject as
  /// a uuid — meaningless in a workspace — and adding the name to the item
  /// itself would change the hash of every mark and re-push all of Firestore.
  Map<String, Object?> encode(SyncItem item, {required String? courseName}) {
    final String status = (item.fields['status'] as String?) ?? 'present';
    final String? tag = item.fields['tag'] as String?;
    final int weight = (item.fields['weight'] as int?) ?? 1;

    final Map<String, Object?> out = <String, Object?>{};
    void put(NotionField field, Object? Function(NotionProperty) value) {
      final NotionProperty? property = mapping.fields[field];
      if (property == null) return;
      final Object? encoded = value(property);
      if (encoded != null) out[property.id] = encoded;
    }

    put(NotionField.key, (_) => _text(item.localKey));
    put(NotionField.date, (_) => <String, Object?>{
          'date': <String, Object?>{'start': _dayOf(item.localKey)},
        });
    put(NotionField.component, (NotionProperty p) => p.type == 'title'
        ? _title(courseName ?? '')
        : _text(courseName ?? ''));
    put(NotionField.course, (NotionProperty p) => _named(p, courseName));
    put(NotionField.status, (NotionProperty p) => _named(p, _word(status, tag)));
    put(NotionField.held, (_) => <String, Object?>{'number': weight});
    // The credit is what decides whether a class counted, and the reader
    // trusts it over the word beside it — so an absence has to say zero
    // rather than leave it unset and read as agreement.
    put(NotionField.credit, (_) => <String, Object?>{
          'number': status == 'present' ? weight : 0,
        });

    return out;
  }

  /// What [decode] will report for this mark once it is written.
  ///
  /// Recorded as the remote hash after a push. Derived here rather than
  /// guessed at, because a hash that does not match what the next read
  /// produces makes every row look changed in Notion on the very next run.
  String remoteHashFor(SyncItem item) => SyncItem(
        kind: SyncKind.attendance,
        localKey: item.localKey,
        fields: remoteFieldsFor(item),
      ).hash;

  Map<String, Object?> remoteFieldsFor(SyncItem item) {
    final String status = (item.fields['status'] as String?) ?? 'present';
    final String? tag = item.fields['tag'] as String?;
    return <String, Object?>{
      'status': _statusFor(_word(status, tag)),
      'weight': (item.fields['weight'] as int?) ?? 1,
    };
  }

  /// The far side's word for this mark.
  ///
  /// A tag wins when the workspace has a value for it: "Proxy" is how the
  /// export has always written a present-with-a-tag, and writing "Present"
  /// instead would lose the distinction the user recorded.
  String? _word(String status, String? tag) {
    final String? tagged = tag == null
        ? null
        : mapping.statusValues[tag.trim().toLowerCase()];
    return tagged ?? mapping.statusValues[status];
  }

  /// Reads one page into the shape the planner compares.
  ///
  /// Null for a page with no key, which is a row a person made by hand: the
  /// import screen is where those are reviewed, and treating one as a synced
  /// row would file it against a class it may have nothing to do with.
  RemoteState? decode(Map<String, Object?> page) {
    final NotionProperty? keyProperty = mapping.fields[NotionField.key];
    final String? id = page['id'] as String?;
    if (keyProperty == null || id == null) return null;

    final Map<String, Object?> properties =
        (page['properties'] as Map<String, Object?>?) ?? <String, Object?>{};
    final String? localKey = _plain(_valueOf(properties, keyProperty));
    if (localKey == null || localKey.isEmpty) return null;

    final String? word = _selected(
      _valueOf(properties, mapping.fields[NotionField.status]),
    );
    final Object? held = _valueOf(properties, mapping.fields[NotionField.held]);

    // Only what Notion actually holds. The hash is compared against its own
    // stored value rather than the local one, so it has to be stable, not
    // identical to what the device would produce.
    final Map<String, Object?> fields = <String, Object?>{
      'status': _statusFor(word),
      'weight': (held is Map<String, Object?> ? held['number'] : null) ?? 1,
    };

    return RemoteState(
      kind: SyncKind.attendance,
      localKey: localKey,
      remoteId: id,
      hash: SyncItem(
        kind: SyncKind.attendance,
        localKey: localKey,
        fields: fields,
      ).hash,
      fields: fields,
      editedAt: DateTime.tryParse((page['last_edited_time'] as String?) ?? ''),
      deleted: page['in_trash'] == true || page['archived'] == true,
    );
  }

  /// The workspace's word back to one of ours, so a renamed option does not
  /// read as a different mark every run.
  String _statusFor(String? option) {
    if (option == null) return 'present';
    for (final MapEntry<String, String> entry in mapping.statusValues.entries) {
      if (entry.value == option) return entry.key;
    }
    return option.trim().toLowerCase();
  }

  /// A select and a status column take the same envelope under different
  /// names, and sending the wrong one is a validation error on every row.
  static Object? _named(NotionProperty property, String? value) {
    if (value == null || value.isEmpty) return null;
    return switch (property.type) {
      'select' => <String, Object?>{
          'select': <String, Object?>{'name': value},
        },
      'status' => <String, Object?>{
          'status': <String, Object?>{'name': value},
        },
      'title' => _title(value),
      'rich_text' => _text(value),
      // A relation points at a page id, which a course name cannot supply.
      _ => null,
    };
  }

  static Map<String, Object?> _text(String value) => <String, Object?>{
        'rich_text': <Object?>[
          <String, Object?>{
            'text': <String, Object?>{'content': value},
          },
        ],
      };

  static Map<String, Object?> _title(String value) => <String, Object?>{
        'title': <Object?>[
          <String, Object?>{
            'text': <String, Object?>{'content': value},
          },
        ],
      };

  /// Notion keys a page's properties by name, not by id, so the column is
  /// found by its id among the values.
  static Object? _valueOf(
    Map<String, Object?> properties,
    NotionProperty? property,
  ) {
    if (property == null) return null;
    for (final Object? value in properties.values) {
      if (value is Map<String, Object?> && value['id'] == property.id) {
        return value;
      }
    }
    return properties[property.name];
  }

  static String? _plain(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final Object? parts = value['rich_text'] ?? value['title'];
    if (parts is! List<Object?>) return null;
    final String joined = parts
        .whereType<Map<String, Object?>>()
        .map((Map<String, Object?> part) => part['plain_text'])
        .whereType<String>()
        .join();
    return joined.isEmpty ? null : joined;
  }

  static String? _selected(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final Object? holder = value['select'] ?? value['status'];
    return holder is Map<String, Object?> ? holder['name'] as String? : null;
  }

  /// `uuid:20260304:540` — the day is the middle part, and the key is the only
  /// place a mark's date survives into a page.
  ///
  /// Written as a plain date with no time, because a mark belongs to a day and
  /// an instant would carry a timezone Notion would then shift.
  static String? _dayOf(String localKey) {
    final List<String> parts = localKey.split(':');
    if (parts.length < 2) return null;
    final int? key = int.tryParse(parts[1]);
    if (key == null) return null;
    final DateTime date = Dates.fromKey(key);
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}
