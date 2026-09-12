import 'timetable_ocr.dart';
import 'vision_read.dart';

/// Folds a model's reading of a sheet into the local parser's.
///
/// The split the measurements forced: the model is good at *what* a class is
/// and cannot place it in time, so where a class sits stays the parser's
/// answer, read off the header row.
class VisionMerge {
  /// Puts each returned class on the grid.
  ///
  /// A reply that names period columns places exactly, which is why the prompt
  /// asks for columns. One that reverts to clocks is snapped to the nearest
  /// band instead, and a class whose columns fall outside the grid is dropped
  /// rather than clamped — a column number the sheet does not have means the
  /// model was counting something else.
  static List<OcrEntry> placedOn(
    TimetableGrid grid,
    List<VisionClass> classes,
  ) {
    final List<(int, int)?> schedule = TimetableOcr.scheduleOf(grid);
    final List<OcrEntry> byClock = <OcrEntry>[];
    final List<OcrEntry> placed = <OcrEntry>[];

    for (final VisionClass c in classes) {
      if (c.byColumn) {
        final (int, int)? start = _bandAt(schedule, c.first!);
        final (int, int)? end = _bandAt(schedule, c.last!);
        if (start == null || end == null || end.$2 <= start.$1) continue;
        placed.add(_entry(c, start.$1, end.$2));
      } else {
        byClock.add(_entry(c, c.from!, c.to!));
      }
    }

    return <OcrEntry>[...placed, ...TimetableOcr.snappedTo(grid, byClock)];
  }

  /// Drops any class the device did not also read **in that cell**.
  ///
  /// Matching the subject anywhere on the page is not enough, and this was
  /// measured rather than reasoned: on a sheet holding 21 classes the model
  /// returned 38, filling nearly every empty period with a course code copied
  /// from elsewhere on the same page. Every one of those passed a whole-page
  /// check, because the codes are real — what makes them wrong is where they
  /// were put.
  ///
  /// So a returned class survives only where ML Kit read text in the cell it
  /// claims. That keeps the case this is for — a cell the device read but
  /// could not parse — and refuses the one it fails at, a cell that is empty.
  static List<OcrEntry> corroboratedBy(
    TimetableGrid grid,
    List<OcrLine> lines,
    List<OcrEntry> entries,
  ) {
    final List<(int, int)?> schedule = TimetableOcr.scheduleOf(grid);
    final Map<int, Set<String>> byCell = <int, Set<String>>{};
    for (final OcrLine line in lines) {
      final ({GridBand day, GridBand period})? cell = grid.cellFor(line.box);
      final int? weekday = cell?.day.weekday;
      if (cell == null || weekday == null) continue;
      final int period = grid.periods.indexOf(cell.period);
      byCell
          .putIfAbsent(_key(weekday, period), () => <String>{})
          .addAll(_runsIn(<OcrLine>[line]));
    }

    return <OcrEntry>[
      for (final OcrEntry e in entries)
        if (_readIn(byCell, schedule, e)) e,
    ];
  }

  /// Whether the device read [e]'s subject under any period its hours cover.
  static bool _readIn(
    Map<int, Set<String>> byCell,
    List<(int, int)?> schedule,
    OcrEntry e,
  ) {
    final String needle = _squashed(e.subject);
    for (int period = 0; period < schedule.length; period++) {
      final (int, int)? span = schedule[period];
      // A lab covers two columns, so every period it overlaps may hold it.
      if (span == null || span.$1 >= e.to || e.from >= span.$2) continue;
      if (byCell[_key(e.weekday, period)]?.contains(needle) ?? false) {
        return true;
      }
    }
    return false;
  }

  static int _key(int weekday, int period) => weekday * 1000 + period;

  /// Adds [extra] only where the local read has nothing at that hour.
  ///
  /// The model is allowed to fill a hole and never to correct one: on every
  /// sheet measured it gets right what the parser gets right, and wrong the
  /// times the parser gets right.
  static List<OcrEntry> filling(
    List<OcrEntry> local,
    List<OcrEntry> extra,
  ) {
    final List<OcrEntry> merged = <OcrEntry>[...local];
    for (final OcrEntry e in extra) {
      final bool taken = merged.any((OcrEntry held) =>
          held.weekday == e.weekday && held.from < e.to && e.from < held.to);
      if (!taken) merged.add(e);
    }
    return merged;
  }

  static (int, int)? _bandAt(List<(int, int)?> schedule, int column) {
    final int index = column - 1;
    return index >= 0 && index < schedule.length ? schedule[index] : null;
  }

  static OcrEntry _entry(VisionClass c, int from, int to) => OcrEntry(
        subject: c.subject,
        weekday: c.weekday,
        from: from,
        to: to,
        room: (c.room?.isEmpty ?? true) ? null : c.room,
      );

  /// Letters and digits only, upper case. The transcript and the reply disagree
  /// about spacing and punctuation constantly and about characters rarely.
  static String _squashed(String s) =>
      s.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  /// Every run of neighbouring words on a line, squashed.
  ///
  /// Whole runs rather than a search through the page as one string, because
  /// `AA1001` is a substring of `AAA1001` — the exact mis-read this is here to
  /// catch would have passed. Runs rather than single words, because a cell is
  /// split into `ABC : DEF : B1` on the page and arrives as one subject.
  static Set<String> _runsIn(List<OcrLine> lines) {
    final Set<String> runs = <String>{};
    for (final OcrLine line in lines) {
      final List<String> words = <String>[
        for (final String word in line.text.split(RegExp('[^A-Za-z0-9]+')))
          if (word.isNotEmpty) _squashed(word),
      ];
      for (int i = 0; i < words.length; i++) {
        final StringBuffer run = StringBuffer();
        for (int j = i; j < words.length; j++) {
          run.write(words[j]);
          runs.add(run.toString());
        }
      }
    }
    return runs;
  }
}
