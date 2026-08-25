import 'package:flutter/foundation.dart';

import 'day_grid.dart';

/// Turns a pasted timetable into weekly classes.
///
/// One class per line — `subject, day, blocks, room, teacher` — because that
/// is what a printed timetable reads like going across a row, and typing it
/// beats twenty trips through the class sheet.
///
/// Deliberately knows nothing about the database or about [Subject]: it reports
/// subject *names* and lets the caller decide which are new. That keeps the
/// whole parse testable against strings, and means an OCR pass can feed the
/// same screen later by producing the same lines.
class TimetableImport {
  const TimetableImport._();

  static TimetableImportResult parse(String text, {required DayGrid grid}) {
    final List<ImportLine> lines = <ImportLine>[];
    final List<String> raw = text.split('\n');

    for (int i = 0; i < raw.length; i++) {
      final String line = raw[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      lines.add(_parseLine(line, i + 1, grid));
    }

    return TimetableImportResult(_withClashesFlagged(lines));
  }

  static ImportLine _parseLine(String line, int number, DayGrid grid) {
    ImportLine fail(String why) =>
        ImportLine(number: number, text: line, error: why);

    final List<String> parts =
        line.split(',').map((String p) => p.trim()).toList();
    if (parts.length < 3) {
      return fail('needs at least a subject, a day and a time');
    }

    final String subject = parts[0];
    if (subject.isEmpty) return fail('no subject');

    final int? weekday = _weekday(parts[1]);
    if (weekday == null) return fail('"${parts[1]}" is not a day');

    final _Span? span = _span(parts[2], grid);
    if (span == null) {
      return fail(grid.isConfigured
          ? '"${parts[2]}" is not a block number or a time'
          : '"${parts[2]}" is not a time, and the day has no blocks to count');
    }
    if (span.error != null) return fail(span.error!);

    String? at(int index) {
      if (parts.length <= index) return null;
      final String value = parts[index];
      return value.isEmpty ? null : value;
    }

    return ImportLine(
      number: number,
      text: line,
      parsed: ImportedClass(
        subjectName: subject,
        weekday: weekday,
        startMinutes: span.start,
        endMinutes: span.end,
        room: at(3),
        teacher: at(4),
        blocks: span.blocks,
      ),
    );
  }

  /// Two meetings of one subject starting at the same minute on the same
  /// weekday would share an attendance key, so the second is refused here for
  /// the same reason the class sheet refuses it.
  static List<ImportLine> _withClashesFlagged(List<ImportLine> lines) {
    final List<ImportLine> out = <ImportLine>[];
    for (final ImportLine line in lines) {
      final ImportedClass? parsed = line.parsed;
      if (parsed == null) {
        out.add(line);
        continue;
      }
      final ImportLine? earlier = out.firstWhereOrNull(
        (ImportLine other) =>
            other.parsed != null && other.parsed!.sharesKeyWith(parsed),
      );
      out.add(
        earlier == null
            ? line
            : ImportLine(
                number: line.number,
                text: line.text,
                error: 'same subject and start time as line ${earlier.number}',
              ),
      );
    }
    return out;
  }

  static int? _weekday(String token) {
    final String t = token.toLowerCase();
    for (int day = 1; day <= 7; day++) {
      if (_dayNames[day - 1].contains(t)) return day;
    }
    return null;
  }

  static const List<Set<String>> _dayNames = <Set<String>>[
    <String>{'mo', 'mon', 'monday'},
    <String>{'tu', 'tue', 'tues', 'tuesday'},
    <String>{'we', 'wed', 'wednesday'},
    <String>{'th', 'thu', 'thur', 'thurs', 'thursday'},
    <String>{'fr', 'fri', 'friday'},
    <String>{'sa', 'sat', 'saturday'},
    <String>{'su', 'sun', 'sunday'},
  ];

  /// A block number, a range of them for a double period, or a clock range for
  /// a timetable whose periods do not match the grid.
  static _Span? _span(String token, DayGrid grid) {
    final RegExpMatch? blocks =
        RegExp(r'^(\d+)\s*(?:-\s*(\d+))?$').firstMatch(token);
    if (blocks != null) {
      if (!grid.isConfigured) return null;
      final int first = int.parse(blocks.group(1)!);
      final int last = int.parse(blocks.group(2) ?? blocks.group(1)!);
      if (first < 1 || last > grid.blockCount) {
        return _Span.bad('the day only has ${grid.blockCount} blocks');
      }
      if (last < first) return _Span.bad('block $last comes before $first');
      return _Span(
        grid.startOf(first - 1),
        grid.endOf(last - 1),
        blocks: last - first + 1,
      );
    }

    final RegExp pattern =
        RegExp(r'^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})$');
    final RegExpMatch? clock = pattern.firstMatch(token);
    if (clock == null) return null;
    final int start =
        int.parse(clock.group(1)!) * 60 + int.parse(clock.group(2)!);
    final int end =
        int.parse(clock.group(3)!) * 60 + int.parse(clock.group(4)!);
    if (end <= start) return _Span.bad('ends before it starts');
    return _Span(
      start,
      end,
      // Clock times need not line up with the grid; a span that is not a whole
      // number of blocks counts as one rather than being rounded into a claim.
      blocks: grid.isConfigured && (end - start) % grid.blockMinutes == 0
          ? (end - start) ~/ grid.blockMinutes
          : 1,
    );
  }
}

@immutable
class ImportedClass {
  const ImportedClass({
    required this.subjectName,
    required this.weekday,
    required this.startMinutes,
    required this.endMinutes,
    this.room,
    this.teacher,
    this.blocks = 1,
  });

  final String subjectName;
  final int weekday;
  final int startMinutes;
  final int endMinutes;
  final String? room;
  final String? teacher;

  /// How many of the day's blocks this class fills, which is what an
  /// institution counting a two-hour lab twice is really counting.
  final int blocks;

  /// Subjects are matched by name, trimmed and case-insensitively, so the same
  /// code typed twice attaches to one subject rather than making two.
  String get subjectKey => subjectName.trim().toLowerCase();

  bool sharesKeyWith(ImportedClass other) =>
      other.subjectKey == subjectKey &&
      other.weekday == weekday &&
      other.startMinutes == startMinutes;
}

@immutable
class ImportLine {
  const ImportLine({
    required this.number,
    required this.text,
    this.parsed,
    this.error,
  });

  /// Counted in the pasted text, blank lines included, so the number shown
  /// matches what the user is looking at.
  final int number;

  final String text;
  final ImportedClass? parsed;
  final String? error;
}

@immutable
class TimetableImportResult {
  const TimetableImportResult(this.lines);

  final List<ImportLine> lines;

  List<ImportedClass> get classes => lines
      .map((ImportLine line) => line.parsed)
      .whereType<ImportedClass>()
      .toList();

  List<ImportLine> get problems =>
      lines.where((ImportLine line) => line.error != null).toList();

  bool get hasProblems => problems.isNotEmpty;

  bool get isEmpty => lines.isEmpty;

  /// Subject names in the order they first appear, so the colours handed out
  /// follow the timetable rather than the alphabet.
  List<String> get subjectNames {
    final Map<String, String> seen = <String, String>{};
    for (final ImportedClass c in classes) {
      seen.putIfAbsent(c.subjectKey, () => c.subjectName.trim());
    }
    return seen.values.toList();
  }

  List<String> get roomNames {
    final Map<String, String> seen = <String, String>{};
    for (final ImportedClass c in classes) {
      final String? room = c.room?.trim();
      if (room == null || room.isEmpty) continue;
      seen.putIfAbsent(room.toLowerCase(), () => room);
    }
    return seen.values.toList();
  }
}

extension _FirstOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final T item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}

@immutable
class _Span {
  const _Span(this.start, this.end, {this.blocks = 1}) : error = null;
  const _Span.bad(this.error) : start = 0, end = 0, blocks = 1;

  final int start;
  final int end;
  final int blocks;
  final String? error;
}
