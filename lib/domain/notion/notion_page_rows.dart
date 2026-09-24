import '../../core/date_utils.dart';
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
    DateTime? today,
  }) {
    final List<NotionRow> rows = <NotionRow>[];
    final List<String> problems = <String>[];
    final Map<String, String> titled = _coursesByTitle(pages, courseNames);
    final int todayKey = Dates.keyOf(today ?? Dates.today());
    int keyed = 0;
    int upcoming = 0;

    for (int i = 0; i < pages.length; i++) {
      final Map<String, Object?> cells = _propertiesOf(pages[i]);
      if (skipKeyed && _keyOf(cells) != null) {
        keyed++;
        continue;
      }
      final ({NotionRow? row, String? problem}) read =
          _rowOf(cells, courseNames, titled, i);
      final NotionRow? row = read.row;
      if (row != null && Dates.keyOf(row.date) > todayKey) {
        upcoming++;
      } else if (row != null) {
        rows.add(row);
      }
      if (read.problem != null) problems.add(read.problem!);
    }

    if (keyed > 0) {
      problems.add('$keyed ${keyed == 1 ? 'row' : 'rows'} already synced from '
          'this device were left out.');
    }
    return NotionExport(rows: rows, problems: problems, upcoming: upcoming);
  }

  /// The rows with no `Zeolite ID`, each beside the page it came from, read
  /// exactly as the import reads them so a claim pairs a page with the mark
  /// that importing it made. A row the import would refuse is left out.
  ///
  /// [strays] are keyed pages to read as unkeyed all the same: their key
  /// names nothing the device holds.
  List<NotionUnkeyedRow> unkeyed(
    List<Map<String, Object?>> pages, {
    Map<String, String> courseNames = const <String, String>{},
    Set<String> strays = const <String>{},
  }) {
    final List<NotionUnkeyedRow> out = <NotionUnkeyedRow>[];
    final Map<String, String> titled = _coursesByTitle(pages, courseNames);
    for (int i = 0; i < pages.length; i++) {
      final Map<String, Object?> page = pages[i];
      final Object? id = page['id'];
      final Map<String, Object?> cells = _propertiesOf(page);
      if (id is! String || page['in_trash'] == true) continue;
      if (page['archived'] == true) continue;
      if (_keyOf(cells) != null && !strays.contains(id)) continue;
      final NotionRow? row = _rowOf(cells, courseNames, titled, i).row;
      if (row != null) out.add(NotionUnkeyedRow(pageId: id, row: row));
    }
    return out;
  }

  Map<String, String> _coursesByTitle(
    List<Map<String, Object?>> pages,
    Map<String, String> courseNames,
  ) =>
      NotionExport.coursesByTitle(<({String title, String course})>[
        for (final Map<String, Object?> page in pages)
          (
            title: _componentOf(_propertiesOf(page))?.trim() ?? '',
            course: _courseOf(_propertiesOf(page), courseNames)?.trim() ?? '',
          ),
      ]);

  ({NotionRow? row, String? problem}) _rowOf(
    Map<String, Object?> cells,
    Map<String, String> courseNames,
    Map<String, String> titled,
    int index,
  ) {
    final String component = _componentOf(cells) ?? '';
    final String named = _courseOf(cells, courseNames)?.trim() ?? '';
    final String course =
        named.isEmpty ? titled[component.trim()] ?? '' : named;
    final String label = component.isEmpty ? course : component;
    final String where = 'Row ${index + 1}${label.isEmpty ? '' : ' ($label)'}';

    final DateTime? date = _dateOf(cells);
    if (date == null) {
      return (row: null, problem: '$where: no date this can read.');
    }
    if (course.isEmpty) return (row: null, problem: '$where: no course named.');

    final String? option = NotionProperties.optionNameOf(
      NotionProperties.valueOf(cells, mapping.fields[NotionField.status]),
    );
    final LogVerdict? meaning = mapping.meaningOf(option);
    if (meaning == LogVerdict.leftOut) return (row: null, problem: null);
    if (meaning == null) {
      return (
        row: null,
        problem: '$where: "${option ?? ''}" is not a status this can read.',
      );
    }

    return (
      row: NotionRow.read(
        component: component,
        course: course,
        kind: _kindOf(cells) ?? NotionKind.lecture,
        date: date,
        status: meaning.word!,
        held: _numberOf(NotionField.held, cells)?.round() ?? 1,
        credit: _numberOf(NotionField.credit, cells)?.round(),
        startMinutes: _timeOf(cells),
        kindLabel: NotionProperties.optionNameOf(
          NotionProperties.valueOf(cells, mapping.fields[NotionField.kind]),
        ),
        tag: meaning.tagged ? option : null,
      ),
      problem: null,
    );
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
    return NotionExport.timeOf(
      NotionProperties.optionNameOf(value) ??
          NotionProperties.plainTextOf(value),
    );
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

/// A hand-made row and the page it lives on.
class NotionUnkeyedRow {
  const NotionUnkeyedRow({required this.pageId, required this.row});

  final String pageId;
  final NotionRow row;
}
