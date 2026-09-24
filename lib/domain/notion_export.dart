import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../core/date_utils.dart';
import '../data/models/attendance_status.dart';
import 'class_log.dart';
import 'notion/notion_mapping.dart';

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
    this.credited,
    this.kindLabel,
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
    String? kindLabel,
    String? tag,
  }) {
    final String raw = status.trim().toLowerCase();
    final AttendanceStatus read = NotionExport._statusOf(raw, held, credit);
    return NotionRow(
      component: component,
      course: course,
      kind: kind,
      date: date,
      status: read,
      // A zero is the app's "does not count", except on a cancellation, which
      // keeps a size for the setting to credit.
      weight: math.max(read == AttendanceStatus.cancelled ? 1 : 0, held),
      startMinutes: startMinutes,
      tagName: tag,
      creditDisagrees: held > 0 && NotionExport._creditDisagrees(raw, credit),
      credited: (raw == 'cancelled' || raw == 'canceled') && credit != null
          ? held > 0 && credit > 0
          : null,
      kindLabel: kindLabel == null || kindLabel.trim().isEmpty
          ? null
          : kindLabel.trim(),
    );
  }

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

  /// Whether the source credited this cancelled class, or null. A mark has
  /// nowhere to keep it; the import sets the app-wide setting from it.
  final bool? credited;

  /// The source's own word for [kind] — `Practical`, `Lab`. Categories are
  /// named from it, so each pairs with that option by name when the type is
  /// written back.
  final String? kindLabel;
}

/// Everything read out of one export, plus what could not be read.
@immutable
class NotionExport {
  const NotionExport({
    required this.rows,
    required this.problems,
    this.upcoming = 0,
  });

  final List<NotionRow> rows;

  /// One line per row that was dropped, saying which and why. Surfaced instead
  /// of swallowed, for the same reason a misread portal row is: a course that
  /// silently loses half its classes reads as an app bug.
  final List<String> problems;

  /// Rows dated after today, left out. A table filled in ahead from a
  /// repeating template holds days still to come, under whatever status the
  /// template defaults to.
  final int upcoming;

  bool get isEmpty => rows.isEmpty;

  /// The course every row with a given title is filed under, for a row that
  /// names none itself — a template whose course came out empty. A title
  /// found under two courses, or none, is left for the row to be reported.
  static Map<String, String> coursesByTitle(
    Iterable<({String title, String course})> rows,
  ) {
    final Map<String, Set<String>> seen = <String, Set<String>>{};
    for (final ({String title, String course}) row in rows) {
      if (row.title.isEmpty || row.course.isEmpty) continue;
      seen.putIfAbsent(row.title, () => <String>{}).add(row.course);
    }
    return <String, String>{
      for (final MapEntry<String, Set<String>> e in seen.entries)
        if (e.value.length == 1) e.key: e.value.single,
    };
  }

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
    if (_findCsv(bytes) == null) {
      return const NotionExport(
        rows: <NotionRow>[],
        problems: <String>['No CSV was found in that file.'],
      );
    }
    final ClassLogTable? table = ClassLogTable.of(bytes);
    if (table == null) {
      return const NotionExport(
        rows: <NotionRow>[],
        problems: <String>['That CSV has no rows in it.'],
      );
    }
    final ClassLogMapping mapping = ClassLogMapping.guess(table);
    if (!<NotionField>[NotionField.course, NotionField.date, NotionField.status]
        .every(mapping.columns.containsKey)) {
      return const NotionExport(
        rows: <NotionRow>[],
        problems: <String>[
          'That CSV is not a Notion class log — it needs a course, a date and '
              'a status column.',
        ],
      );
    }
    return readClassLog(table, mapping, today: today);
  }

  /// The file's CSV as cells, wherever in the export it sits.
  static List<List<String>>? csvCells(Uint8List bytes) {
    final String? csv = _findCsv(bytes);
    return csv == null ? null : readCsv(csv);
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

  /// The credit column decides whether a class was attended, not the word
  /// beside it — except a cancellation, which stays one so the setting can
  /// decide, and a `Held` of zero, whose credit means nothing.
  static AttendanceStatus _statusOf(String raw, int held, int? credit) {
    if (raw == 'cancelled' || raw == 'canceled') {
      return AttendanceStatus.cancelled;
    }
    if (credit == null || held == 0) {
      return raw == 'absent'
          ? AttendanceStatus.absent
          : AttendanceStatus.present;
    }
    return credit > 0 ? AttendanceStatus.present : AttendanceStatus.absent;
  }

  /// Cancelled is exempt — see [NotionRow.creditDisagrees] — or the export's
  /// own rule would be reported as a fault on every one of them.
  static bool _creditDisagrees(String raw, int? credit) {
    if (credit == null || raw == 'cancelled' || raw == 'canceled') return false;
    return raw == 'absent' ? credit > 0 : credit == 0;
  }

  /// `Thermodynamics (https://notion.so/...)` — Notion appends the page link
  /// to every relation cell.
  /// `09:00` as minutes past midnight, or null.
  static int? timeOf(String? text) {
    if (text == null) return null;
    final Match? match = RegExp(r'^\s*(\d{1,2}):(\d{2})').firstMatch(text);
    if (match == null) return null;
    final int hour = int.parse(match.group(1)!);
    final int minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }

  static String courseName(String cell) {
    final int link = cell.indexOf(' (http');
    return (link < 0 ? cell : cell.substring(0, link)).trim();
  }

  static const List<String> _months = <String>[
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  /// Reads `Jul 27`, `July 27, 2025`, an ISO date, or a numeric one such as
  /// `27/07/2025` in the order [dayFirst] gives — null leaves a numeric date
  /// unread, since `05/08` is a different day either way.
  ///
  /// With no year printed — which is what Notion does inside the current year
  /// — the date is placed at its most recent occurrence on or before [today].
  /// A term running across new year then splits correctly: January lands in
  /// this year and December in the last.
  static DateTime? dateOf(String cell, DateTime today, {bool? dayFirst}) {
    final String value = cell.trim();
    if (value.isEmpty) return null;

    final DateTime? iso = DateTime.tryParse(value);
    if (iso != null) return DateTime(iso.year, iso.month, iso.day);

    final List<int>? numbers = ClassLogMapping.numericDate(value);
    if (numbers != null) {
      if (dayFirst == null) return null;
      final int day = dayFirst ? numbers[0] : numbers[1];
      final int month = dayFirst ? numbers[1] : numbers[0];
      final int year = numbers[2] < 100 ? 2000 + numbers[2] : numbers[2];
      final DateTime date = DateTime(year, month, day);
      // DateTime rolls 31/02 into March; a date that moved was not a date.
      return date.day == day && date.month == month ? date : null;
    }

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
