import '../notion_export.dart';
import 'notion_mapping.dart';
import 'notion_properties.dart';

/// Reads the pages of a mapped data source into the rows the import preview
/// already takes.
///
/// The API is a second *source* for that preview, not a second importer, so
/// this produces a [NotionExport] and stops. Pure: the pages are handed in,
/// which is what makes the conversion testable without a workspace.
class NotionPageRows {
  const NotionPageRows(this.mapping);

  final NotionMapping mapping;

  /// The pages a `Course` relation points at, so their titles can be read
  /// before [read] runs. Empty unless the column really is a relation —
  /// every other type names the course in the cell itself.
  Set<String> relatedCourseIds(List<Map<String, Object?>> pages) {
    final NotionProperty? course = mapping.fields[NotionField.course];
    if (course == null || course.type != 'relation') return const <String>{};

    return <String>{
      for (final Map<String, Object?> page in pages)
        ...NotionProperties.relationIdsOf(
          NotionProperties.valueOf(_propertiesOf(page), course),
        ),
    };
  }

  /// [courseNames] maps a related page id to its title, from
  /// [relatedCourseIds]. An id with no title left is a course that could not
  /// be named, and its rows are reported rather than filed under nothing.
  ///
  /// [skipKeyed] leaves out rows this app wrote itself, which is what somebody
  /// importing into a device that is already syncing means; a device being set
  /// up again from Notion wants all of them.
  NotionExport read(
    List<Map<String, Object?>> pages, {
    Map<String, String> courseNames = const <String, String>{},
    bool skipKeyed = false,
  }) {
    final NotionProperties properties = NotionProperties(mapping);
    final List<NotionRow> rows = <NotionRow>[];
    final List<String> problems = <String>[];
    int keyed = 0;

    for (int i = 0; i < pages.length; i++) {
      final Map<String, Object?> cells = _propertiesOf(pages[i]);
      if (skipKeyed && _keyOf(cells) != null) {
        keyed++;
        continue;
      }

      final String course = _courseOf(cells, courseNames) ?? '';
      final String component = _componentOf(cells) ?? '';
      final String label = component.isEmpty ? course : component;
      final String where = 'Row ${i + 1}${label.isEmpty ? '' : ' ($label)'}';

      final DateTime? date = _dateOf(cells);
      if (date == null) {
        problems.add('$where: no date this can read.');
        continue;
      }
      if (course.isEmpty) {
        problems.add('$where: no course named.');
        continue;
      }

      final String? option = NotionProperties.optionNameOf(
        NotionProperties.valueOf(cells, mapping.fields[NotionField.status]),
      );
      final String? word = properties.wordFor(option);
      if (word == null || !NotionRow.knowsStatus(word)) {
        problems.add('$where: "${option ?? ''}" is not a status this can '
            'read.');
        continue;
      }

      rows.add(
        NotionRow.read(
          component: component,
          course: course,
          kind: _kindOf(cells) ?? NotionKind.lecture,
          date: date,
          status: word,
          held: _numberOf(NotionField.held, cells)?.round() ?? 1,
          credit: _numberOf(NotionField.credit, cells)?.round(),
          startMinutes: _timeOf(cells),
        ),
      );
    }

    if (keyed > 0) {
      problems.add('$keyed ${keyed == 1 ? 'row' : 'rows'} already synced from '
          'this device were left out.');
    }
    return NotionExport(rows: rows, problems: problems);
  }

  /// Whether any row carries a `Zeolite ID`, and so whether leaving this
  /// device's own rows out would change anything worth asking about.
  bool hasKeyed(List<Map<String, Object?>> pages) => pages
      .any((Map<String, Object?> page) => _keyOf(_propertiesOf(page)) != null);

  /// A course can be named in the cell or sit behind a relation, and the
  /// mapping screen offers every one of these types.
  String? _courseOf(
    Map<String, Object?> cells,
    Map<String, String> courseNames,
  ) {
    final NotionProperty? property = mapping.fields[NotionField.course];
    if (property == null) return null;
    final Object? value = NotionProperties.valueOf(cells, property);

    return switch (property.type) {
      'relation' => NotionProperties.relationIdsOf(value)
          .map((String id) => courseNames[id])
          .whereType<String>()
          .firstOrNull,
      'select' || 'status' => NotionProperties.optionNameOf(value),
      'multi_select' => NotionProperties.firstOptionOf(value),
      _ => NotionProperties.plainTextOf(value),
    };
  }

  String? _componentOf(Map<String, Object?> cells) =>
      NotionProperties.plainTextOf(
        NotionProperties.valueOf(cells, mapping.fields[NotionField.component]),
      );

  /// Through the user's own pairing first: a workspace whose `Type` options
  /// are named for its own categories only reads as lecture/tutorial/practical
  /// once they are put back into Zeolite's words.
  NotionKind? _kindOf(Map<String, Object?> cells) {
    final String? option = NotionProperties.optionNameOf(
      NotionProperties.valueOf(cells, mapping.fields[NotionField.kind]),
    );
    if (option == null) return null;

    for (final MapEntry<String, String> entry in mapping.kindValues.entries) {
      if (entry.value == option) {
        final NotionKind? paired = NotionKind.fromLabel(entry.key);
        if (paired != null) return paired;
      }
    }
    return NotionKind.fromLabel(option);
  }

  /// Sliced, not parsed whole: a row with a time carries an offset, and
  /// resolving it moves the class across midnight in either direction.
  DateTime? _dateOf(Map<String, Object?> cells) {
    final String? start = NotionProperties.dateStartOf(
      NotionProperties.valueOf(cells, mapping.fields[NotionField.date]),
    );
    if (start == null || start.length < 10) return null;
    final DateTime? day = DateTime.tryParse(start.substring(0, 10));
    return day == null ? null : DateTime(day.year, day.month, day.day);
  }

  /// `HH:mm` off the optional Time column, or null when there is none this
  /// can read. A column full of prose is not an error: the importer places the
  /// row itself in that case, exactly as it did before the column existed.
  int? _timeOf(Map<String, Object?> cells) {
    final Object? value = NotionProperties.valueOf(
      cells,
      mapping.fields[NotionField.time],
    );
    final String? text = NotionProperties.optionNameOf(value) ??
        NotionProperties.plainTextOf(value);
    if (text == null) return null;
    final Match? match =
        RegExp(r'^\s*(\d{1,2}):(\d{2})').firstMatch(text);
    if (match == null) return null;
    final int hour = int.parse(match.group(1)!);
    final int minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }

  num? _numberOf(NotionField field, Map<String, Object?> cells) =>
      NotionProperties.numberOf(
        NotionProperties.valueOf(cells, mapping.fields[field]),
      );

  String? _keyOf(Map<String, Object?> cells) {
    final NotionProperty? key = mapping.fields[NotionField.key];
    if (key == null) return null;
    final String? value =
        NotionProperties.plainTextOf(NotionProperties.valueOf(cells, key));
    return value == null || value.isEmpty ? null : value;
  }

  static Map<String, Object?> _propertiesOf(Map<String, Object?> page) =>
      (page['properties'] as Map<String, Object?>?) ?? <String, Object?>{};
}
