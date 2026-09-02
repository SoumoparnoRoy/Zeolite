import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../core/date_utils.dart';
import '../data/models/attendance_status.dart';

/// Which part of a course a row belongs to.
enum NotionKind {
  lecture,
  tutorial,
  practical;

  static NotionKind? fromLabel(String value) {
    final String v = value.trim().toLowerCase();
    if (v.startsWith('lec')) return NotionKind.lecture;
    if (v.startsWith('tut')) return NotionKind.tutorial;
    if (v.startsWith('prac') || v.startsWith('lab')) return NotionKind.practical;
    return null;
  }

  /// What a separate subject for this component gets called, given the course.
  ///
  /// A tutorial belongs with the theory rather than standing on its own: it is
  /// the same class counted the same way, and only the practical is assessed
  /// apart.
  ///
  /// A course already ending in the word keeps it. The app files its own lab
  /// subjects in Notion under their full names, so appending regardless
  /// brought them back doubled, and as new subjects rather than the ones they
  /// left as.
  String subjectName(String course) {
    if (this != NotionKind.practical) return course;
    final List<String> words = course.trimRight().split(RegExp(r'\s+'));
    return words.last.toLowerCase() == 'lab' ? course : '$course Lab';
  }
}

/// One class occurrence as the export records it.
@immutable
class NotionRow {
  const NotionRow({
    required this.component,
    required this.course,
    required this.kind,
    required this.date,
    required this.status,
    required this.weight,
    this.tagName,
    this.startMinutes,
    this.creditDisagrees = false,
  });

  /// One row off a status word and the two counters, wherever they were read
  /// from — a CSV cell or a page property.
  ///
  /// The judgement lives here rather than in each reader: which of the three
  /// statuses a row lands on is the only thing an export cannot say plainly,
  /// and two copies of that rule would drift apart.
  factory NotionRow.read({
    required String component,
    required String course,
    required NotionKind kind,
    required DateTime date,
    required String status,
    required int held,
    int? credit,
    int? startMinutes,
  }) {
    final String raw = status.trim().toLowerCase();
    return NotionRow(
      component: component,
      course: course,
      kind: kind,
      date: date,
      status: NotionExport._statusOf(raw, held, credit),
      weight: math.max(1, held),
      startMinutes: startMinutes,
      tagName: switch (raw) {
        'proxy' => 'Proxy',
        'cancelled' || 'canceled' => 'Cancelled',
        _ => null,
      },
      creditDisagrees: NotionExport._creditDisagrees(raw, credit),
    );
  }

  /// Whether a reader has anywhere to put this word.
  static bool knowsStatus(String status) =>
      NotionExport._known.contains(status.trim().toLowerCase());

  /// When the class started, if the source said. Null is the ordinary case —
  /// only a `Time` column can supply it — and leaves the importer to place the
  /// row itself.
  final int? startMinutes;

  /// The per-component code the export uses as a page title, e.g. `ABC101P`.
  final String component;

  /// The course the component belongs to, e.g. `Thermodynamics`.
  final String course;

  final NotionKind kind;
  final DateTime date;
  final AttendanceStatus status;

  /// How many classes the export counts this one occurrence as.
  final int weight;

  /// The label the export gave this class — "Proxy", "Cancelled" — for
  /// anything the three statuses cannot say on their own. Null for a plain
  /// present or absent.
  final String? tagName;

  /// The written status and the credit column tell different stories: present
  /// but credited nothing, or absent and credited anyway. The credit still
  /// decides, so this only says the sheet contradicts itself.
  final bool creditDisagrees;
}

/// Everything read out of one export, plus what could not be read.
@immutable
class NotionExport {
  const NotionExport({required this.rows, required this.problems});

  final List<NotionRow> rows;

  /// One line per row that was dropped, saying which and why. Surfaced instead
  /// of swallowed, for the same reason a misread portal row is: a course that
  /// silently loses half its classes reads as an app bug.
  final List<String> problems;

  bool get isEmpty => rows.isEmpty;

  DateTime? get firstDate => rows.isEmpty
      ? null
      : rows.map((NotionRow r) => r.date).reduce(
            (DateTime a, DateTime b) => a.isBefore(b) ? a : b,
          );

  DateTime? get lastDate => rows.isEmpty
      ? null
      : rows.map((NotionRow r) => r.date).reduce(
            (DateTime a, DateTime b) => a.isAfter(b) ? a : b,
          );

  /// Reads a Notion database export.
  ///
  /// Accepts the zip Notion hands you, the zip inside it, or a bare CSV — the
  /// export nests one zip inside another and Android has no comfortable way to
  /// unpack that by hand.
  ///
  /// [today] anchors the year, which the export leaves off. Injected so the
  /// inference is testable rather than tied to the clock.
  static NotionExport read(Uint8List bytes, {DateTime? today}) {
    final String? csv = _findCsv(bytes);
    if (csv == null) {
      return const NotionExport(
        rows: <NotionRow>[],
        problems: <String>['No CSV was found in that file.'],
      );
    }
    return _parse(csv, today ?? Dates.today());
  }

  /// Walks a zip for the export's CSV, one level of nesting deep.
  ///
  /// Notion writes both `<name>.csv` and `<name>_all.csv`; the second ignores
  /// the view's filters, so it is the one that holds every class.
  static String? _findCsv(Uint8List bytes) {
    if (!_looksLikeZip(bytes)) return _decode(bytes);

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object {
      return null;
    }

    final List<ArchiveFile> files =
        archive.files.where((ArchiveFile f) => f.isFile).toList();

    String? best;
    for (final ArchiveFile file in files) {
      final String name = file.name.toLowerCase();
      if (!name.endsWith('.csv')) continue;
      final String text = _decode(file.readBytes() ?? Uint8List(0));
      if (name.endsWith('_all.csv')) return text;
      best ??= text;
    }
    if (best != null) return best;

    for (final ArchiveFile file in files) {
      if (!file.name.toLowerCase().endsWith('.zip')) continue;
      final Uint8List? inner = file.readBytes();
      if (inner == null || !_looksLikeZip(inner)) continue;
      // One level only: a zip inside a zip inside a zip is not something
      // Notion produces, and recursing without a bound invites a bomb.
      final String? found = _findCsv(inner);
      if (found != null) return found;
    }
    return null;
  }

  static bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;

  /// Notion writes UTF-8 with a byte-order mark, which would otherwise stay
  /// glued to the first header and stop it matching.
  static String _decode(Uint8List bytes) {
    final String text = utf8.decode(bytes, allowMalformed: true);
    return text.startsWith('﻿') ? text.substring(1) : text;
  }

  static NotionExport _parse(String csv, DateTime today) {
    final List<List<String>> table = readCsv(csv);
    if (table.isEmpty) {
      return const NotionExport(
        rows: <NotionRow>[],
        problems: <String>['That CSV has no rows in it.'],
      );
    }

    final _Columns? columns = _Columns.from(table.first);
    if (columns == null) {
      return const NotionExport(
        rows: <NotionRow>[],
        problems: <String>[
          'That CSV is not a Notion class log — it needs a course, a date and '
              'a status column.',
        ],
      );
    }

    final List<NotionRow> rows = <NotionRow>[];
    final List<String> problems = <String>[];

    for (int i = 1; i < table.length; i++) {
      final List<String> cells = table[i];
      if (cells.every((String c) => c.trim().isEmpty)) continue;

      String at(int? index) =>
          index == null || index >= cells.length ? '' : cells[index].trim();

      final String course = _courseName(at(columns.course));
      final String component = at(columns.component);
      final String label = component.isEmpty ? course : component;

      final DateTime? date = _date(at(columns.date), today);
      if (date == null) {
        problems.add('Row ${i + 1} ($label): "${at(columns.date)}" is not a '
            'date.');
        continue;
      }
      if (course.isEmpty) {
        problems.add('Row ${i + 1}: no course named.');
        continue;
      }

      final String raw = at(columns.status).toLowerCase();
      if (!NotionRow.knowsStatus(raw)) {
        problems.add('Row ${i + 1} ($label): "${at(columns.status)}" is not a '
            'status this can read.');
        continue;
      }

      final int held = int.tryParse(at(columns.held)) ?? 1;
      final int? credit = int.tryParse(at(columns.credit));

      rows.add(
        NotionRow.read(
          component: component,
          course: course,
          kind: NotionKind.fromLabel(at(columns.kind)) ?? NotionKind.lecture,
          date: date,
          status: raw,
          held: held,
          credit: credit,
        ),
      );
    }

    return NotionExport(rows: rows, problems: problems);
  }

  static const Set<String> _known = <String>{
    'present',
    'absent',
    'proxy',
    'cancelled',
    'canceled',
  };

  /// The credit column decides whether a class counted, not the word beside it.
  ///
  /// An institution can credit a cancelled class in full — this one does — and
  /// hard-coding either reading puts every such class on the wrong side. The
  /// export records the answer per row, so it is read rather than assumed.
  /// Only when the column is missing does the word have to stand in.
  ///
  /// `Held` of zero means the class never happened, the one case that counts
  /// towards neither side.
  static AttendanceStatus _statusOf(String raw, int held, int? credit) {
    final bool cancelled = raw == 'cancelled' || raw == 'canceled';
    if (held == 0) return AttendanceStatus.cancelled;
    if (credit == null) {
      if (cancelled) return AttendanceStatus.cancelled;
      return raw == 'absent'
          ? AttendanceStatus.absent
          : AttendanceStatus.present;
    }
    if (credit > 0) return AttendanceStatus.present;
    // Uncredited and cancelled is not an absence — it is a class that counted
    // for nobody either way.
    return cancelled ? AttendanceStatus.cancelled : AttendanceStatus.absent;
  }

  /// Cancelled is exempt — see [NotionRow.creditDisagrees] — or the export's
  /// own rule would be reported as a fault on every one of them.
  static bool _creditDisagrees(String raw, int? credit) {
    if (credit == null || raw == 'cancelled' || raw == 'canceled') return false;
    return raw == 'absent' ? credit > 0 : credit == 0;
  }

  /// `Thermodynamics (https://notion.so/...)` — Notion appends the page link
  /// to every relation cell.
  static String _courseName(String cell) {
    final int link = cell.indexOf(' (http');
    return (link < 0 ? cell : cell.substring(0, link)).trim();
  }

  static const List<String> _months = <String>[
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  /// Reads `Jul 27`, `July 27, 2025` or an ISO date.
  ///
  /// With no year printed — which is what Notion does inside the current year
  /// — the date is placed at its most recent occurrence on or before [today].
  /// A term running across new year then splits correctly: January lands in
  /// this year and December in the last.
  static DateTime? _date(String cell, DateTime today) {
    final String value = cell.trim();
    if (value.isEmpty) return null;

    final DateTime? iso = DateTime.tryParse(value);
    if (iso != null) return DateTime(iso.year, iso.month, iso.day);

    final RegExpMatch? match = RegExp(
      r'^([A-Za-z]{3,})\.?\s+(\d{1,2})(?:\s*,?\s*(\d{4}))?$',
    ).firstMatch(value);
    if (match == null) return null;

    final int month =
        _months.indexOf(match.group(1)!.toLowerCase().substring(0, 3)) + 1;
    if (month == 0) return null;
    final int day = int.parse(match.group(2)!);
    if (day < 1 || day > 31) return null;

    final String? year = match.group(3);
    if (year != null) return DateTime(int.parse(year), month, day);

    final DateTime thisYear = DateTime(today.year, month, day);
    return Dates.keyOf(thisYear) <= Dates.keyOf(today)
        ? thisYear
        : DateTime(today.year - 1, month, day);
  }
}

/// Which column holds what, located by header name.
///
/// Matched loosely because the columns are the user's own: they can be
/// reordered, and the two counters are named after their own values.
class _Columns {
  const _Columns({
    required this.course,
    required this.date,
    required this.status,
    this.component,
    this.kind,
    this.held,
    this.credit,
  });

  final int course;
  final int date;
  final int status;
  final int? component;
  final int? kind;
  final int? held;
  final int? credit;

  static _Columns? from(List<String> header) {
    int? find(bool Function(String) test) {
      for (int i = 0; i < header.length; i++) {
        if (test(header[i].trim().toLowerCase())) return i;
      }
      return null;
    }

    final int? course = find((String h) => h == 'course');
    final int? date = find((String h) => h == 'date');
    final int? status = find((String h) => h == 'status');
    if (course == null || date == null || status == null) return null;

    return _Columns(
      course: course,
      date: date,
      status: status,
      component: find((String h) => h == 'name'),
      kind: find((String h) => h.contains('l/t/p') || h == 'type'),
      // "Held?" is a yes/no beside it, so the counter is the one carrying its
      // own values in the name.
      held: find((String h) => h.startsWith('held') && h.contains('/')),
      credit: find((String h) => h.contains('credit')),
    );
  }
}

/// Splits CSV text into rows of cells, honouring quotes.
///
/// Hand-rolled rather than pulled in: the whole grammar is quoting, doubled
/// quotes and newlines inside a quoted cell, and the export is written by a
/// machine so nothing else turns up.
List<List<String>> readCsv(String text) {
  final List<List<String>> rows = <List<String>>[];
  List<String> row = <String>[];
  final StringBuffer cell = StringBuffer();
  bool quoted = false;

  void endCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void endRow() {
    endCell();
    rows.add(row);
    row = <String>[];
  }

  for (int i = 0; i < text.length; i++) {
    final String c = text[i];
    if (quoted) {
      if (c != '"') {
        cell.write(c);
      } else if (i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = false;
      }
      continue;
    }
    switch (c) {
      case '"':
        quoted = true;
      case ',':
        endCell();
      case '\r':
        break;
      case '\n':
        endRow();
      default:
        cell.write(c);
    }
  }
  // A file that does not end in a newline still has a last row.
  if (cell.isNotEmpty || row.isNotEmpty) endRow();

  return rows;
}
