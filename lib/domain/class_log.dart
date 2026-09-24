import 'package:flutter/foundation.dart';

import '../core/date_utils.dart';
import 'notion/notion_mapping.dart';
import 'notion_export.dart';

/// A class log's cells, before anything is decided about what they mean.
@immutable
class ClassLogTable {
  const ClassLogTable({required this.header, required this.rows});

  final List<String> header;
  final List<List<String>> rows;

  /// Null when the file holds no CSV at all, or one with no rows.
  static ClassLogTable? of(Uint8List bytes) {
    final List<List<String>>? cells = NotionExport.csvCells(bytes);
    if (cells == null || cells.length < 2) return null;
    return ClassLogTable(
      header: <String>[for (final String h in cells.first) h.trim()],
      rows: cells.skip(1).toList(),
    );
  }

  String cell(List<String> row, int? column) =>
      column == null || column >= row.length ? '' : row[column].trim();

  /// Every value [column] holds, in first-seen order and spelling.
  List<String> valuesOf(int? column) {
    final Map<String, String> seen = <String, String>{};
    for (final List<String> row in rows) {
      final String value = cell(row, column);
      if (value.isNotEmpty) seen.putIfAbsent(value.toLowerCase(), () => value);
    }
    return seen.values.toList();
  }

  /// Identifies the layout, so a mapping made once is found again for next
  /// month's file from the same place.
  String get layout => header.map((String h) => h.toLowerCase()).join('|');
}

/// Which column holds what in one class log, and what its words mean.
@immutable
class ClassLogMapping {
  const ClassLogMapping({
    required this.columns,
    this.statuses = const <String, LogVerdict>{},
    this.types = const <String, NotionKind>{},
    this.dayFirst,
  });

  /// Only the fields a log can carry; the key column is the app's own.
  static const List<NotionField> fields = <NotionField>[
    NotionField.course,
    NotionField.date,
    NotionField.status,
    NotionField.component,
    NotionField.time,
    NotionField.kind,
    NotionField.held,
    NotionField.credit,
  ];

  final Map<NotionField, int> columns;

  /// By the word lowercased.
  final Map<String, LogVerdict> statuses;
  final Map<String, NotionKind> types;

  /// How to read `05/08/2026`. Null until the file or the user settles it.
  final bool? dayFirst;

  /// Everything the file itself makes plain: columns by name, the four
  /// status words the app has always read, types by their usual prefixes,
  /// and the date order where a day above twelve gives it away.
  static ClassLogMapping guess(ClassLogTable table) {
    final Map<NotionField, int> columns = <NotionField, int>{};
    for (final NotionField field in fields) {
      for (int i = 0; i < table.header.length; i++) {
        if (columns.containsValue(i)) continue;
        if (field.matches(table.header[i])) {
          columns[field] = i;
          break;
        }
      }
    }
    return ClassLogMapping(columns: columns).withGuessedWords(table);
  }

  /// Fills in the words for whatever columns are now chosen, keeping any
  /// answer already given.
  ClassLogMapping withGuessedWords(ClassLogTable table) {
    final Map<String, LogVerdict> statuses = <String, LogVerdict>{
      for (final String word in table.valuesOf(columns[NotionField.status]))
        if (LogVerdict.guess(word) case final LogVerdict v) word.toLowerCase(): v,
      ...this.statuses,
    };
    final Map<String, NotionKind> types = <String, NotionKind>{
      for (final String word in table.valuesOf(columns[NotionField.kind]))
        if (NotionKind.fromLabel(word) case final NotionKind k)
          word.toLowerCase(): k,
      ...this.types,
    };
    return copyWith(
      statuses: statuses,
      types: types,
      dayFirst: dayFirst ??
          _dateOrder(table.valuesOf(columns[NotionField.date])),
    );
  }

  /// Day first if some date's first number is above twelve, month first if
  /// some date's second is; null when neither or both happen.
  static bool? _dateOrder(List<String> dates) {
    bool sawDayFirst = false;
    bool sawMonthFirst = false;
    for (final String value in dates) {
      final List<int>? parts = numericDate(value);
      if (parts == null) continue;
      if (parts[0] > 12) sawDayFirst = true;
      if (parts[1] > 12) sawMonthFirst = true;
    }
    if (sawDayFirst == sawMonthFirst) return null;
    return sawDayFirst;
  }

  /// Whether there are numeric dates and none of them settles the order —
  /// the one case the user is asked.
  static bool datesAreAmbiguous(ClassLogTable table, int? column) {
    final List<String> values = table.valuesOf(column);
    return values.any((String v) => numericDate(v) != null) &&
        _dateOrder(values) == null;
  }

  /// `05/08/2026`, `5-8-26`, `5.8.2026` as its three numbers, or null.
  static List<int>? numericDate(String value) {
    final RegExpMatch? m =
        RegExp(r'^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2}|\d{4})$')
            .firstMatch(value.trim());
    if (m == null) return null;
    return <int>[
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    ];
  }

  /// Whether this can be read without asking: the three columns every row
  /// needs, a meaning for every status word in the file, and a date order
  /// wherever the dates leave one open.
  bool readyFor(ClassLogTable table) {
    if (!NotionField.values
        .where((NotionField f) => f.isRequired && fields.contains(f))
        .every(columns.containsKey)) {
      return false;
    }
    final bool wordsKnown = table
        .valuesOf(columns[NotionField.status])
        .every((String w) => statuses.containsKey(w.toLowerCase()));
    final bool datesKnown = dayFirst != null ||
        !datesAreAmbiguous(table, columns[NotionField.date]);
    return wordsKnown && datesKnown;
  }

  ClassLogMapping copyWith({
    Map<NotionField, int>? columns,
    Map<String, LogVerdict>? statuses,
    Map<String, NotionKind>? types,
    bool? dayFirst,
  }) =>
      ClassLogMapping(
        columns: columns ?? this.columns,
        statuses: statuses ?? this.statuses,
        types: types ?? this.types,
        dayFirst: dayFirst ?? this.dayFirst,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'columns': <String, int>{
          for (final MapEntry<NotionField, int> e in columns.entries)
            e.key.name: e.value,
        },
        'statuses': <String, String>{
          for (final MapEntry<String, LogVerdict> e in statuses.entries)
            e.key: e.value.name,
        },
        'types': <String, String>{
          for (final MapEntry<String, NotionKind> e in types.entries)
            e.key: e.value.name,
        },
        'dayFirst': dayFirst,
      };

  /// Anything unreadable in a stored mapping is dropped rather than trusted:
  /// the worst case is being asked again.
  static ClassLogMapping? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    T? named<T extends Enum>(List<T> values, Object? name) =>
        values.where((T v) => v.name == name).firstOrNull;
    final Object? columns = raw['columns'];
    final Object? statuses = raw['statuses'];
    final Object? types = raw['types'];
    return ClassLogMapping(
      columns: <NotionField, int>{
        if (columns is Map<String, Object?>)
          for (final MapEntry<String, Object?> e in columns.entries)
            if (named(NotionField.values, e.key) case final NotionField f)
              if (e.value case final int i) f: i,
      },
      statuses: <String, LogVerdict>{
        if (statuses is Map<String, Object?>)
          for (final MapEntry<String, Object?> e in statuses.entries)
            if (named(LogVerdict.values, e.value) case final LogVerdict v)
              e.key: v,
      },
      types: <String, NotionKind>{
        if (types is Map<String, Object?>)
          for (final MapEntry<String, Object?> e in types.entries)
            if (named(NotionKind.values, e.value) case final NotionKind k)
              e.key: k,
      },
      dayFirst: raw['dayFirst'] as bool?,
    );
  }
}

/// Turns a table into the rows the preview reads, through a mapping.
///
/// The credit, `Held` and cancellation rules are [NotionRow.read]'s, the same
/// ones the connected-table import applies; only the words and the columns
/// come from the mapping.
NotionExport readClassLog(
  ClassLogTable table,
  ClassLogMapping mapping, {
  DateTime? today,
}) {
  final DateTime anchor = today ?? Dates.today();
  final Map<NotionField, int> at = mapping.columns;
  final List<NotionRow> rows = <NotionRow>[];
  final List<String> problems = <String>[];
  final Map<String, String> titled = NotionExport.coursesByTitle(
    <({String title, String course})>[
      for (final List<String> cells in table.rows)
        (
          title: table.cell(cells, at[NotionField.component]),
          course: NotionExport.courseName(
            table.cell(cells, at[NotionField.course]),
          ),
        ),
    ],
  );
  int upcoming = 0;

  for (int i = 0; i < table.rows.length; i++) {
    final List<String> cells = table.rows[i];
    if (cells.every((String c) => c.trim().isEmpty)) continue;
    String get(NotionField field) => table.cell(cells, at[field]);

    final String component = get(NotionField.component);
    final String named = NotionExport.courseName(get(NotionField.course));
    final String course = named.isEmpty ? titled[component] ?? '' : named;
    final String label = component.isEmpty ? course : component;
    final String where = 'Row ${i + 2}${label.isEmpty ? '' : ' ($label)'}';

    final DateTime? date = NotionExport.dateOf(
      get(NotionField.date),
      anchor,
      dayFirst: mapping.dayFirst,
    );
    if (date == null) {
      problems.add('$where: "${get(NotionField.date)}" is not a date this can '
          'read.');
      continue;
    }
    if (course.isEmpty) {
      problems.add('$where: no course named.');
      continue;
    }

    final String said = get(NotionField.status);
    final LogVerdict? verdict = mapping.statuses[said.toLowerCase()];
    if (verdict == null) {
      problems.add('$where: "$said" is not a status this can read.');
      continue;
    }
    if (verdict == LogVerdict.leftOut) continue;
    if (Dates.keyOf(date) > Dates.keyOf(anchor)) {
      upcoming++;
      continue;
    }

    final String kindWord = get(NotionField.kind);
    rows.add(
      NotionRow.read(
        component: component,
        course: course,
        kind: mapping.types[kindWord.toLowerCase()] ??
            NotionKind.fromLabel(kindWord) ??
            NotionKind.lecture,
        date: date,
        status: verdict.word!,
        held: int.tryParse(get(NotionField.held)) ?? 1,
        credit: int.tryParse(get(NotionField.credit)),
        startMinutes: NotionExport.timeOf(get(NotionField.time)),
        kindLabel: kindWord,
        tag: verdict.tagged ? said : null,
      ),
    );
  }
  return NotionExport(rows: rows, problems: problems, upcoming: upcoming);
}
