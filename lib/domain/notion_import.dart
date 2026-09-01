import '../core/date_utils.dart';
import '../data/models/attendance_record.dart';
import '../data/models/attendance_status.dart';
import '../data/models/class_slot.dart';
import '../data/models/subject.dart';
import 'notion_export.dart';

/// Whether a course's components share one subject or get one each.
///
/// The export cannot answer this: an institution that counts a two-hour lab
/// twice usually reports the course as a whole, and one that gives the lab its
/// own attendance requirement reports them apart. Both are real, so it is
/// offered rather than guessed.
enum NotionGrouping {
  /// One subject per course. A practical keeps the weight the export gives it,
  /// so a two-period lab counts twice inside its course's percentage.
  grouped,

  /// One subject per component — "Thermodynamics" and "Thermodynamics Lab" —
  /// each counting every occurrence once, with its own target.
  separate,
}

/// What importing one subject's rows would do.
enum NotionMatch {
  /// No subject of that name — it would be created.
  create,

  /// Already stored, with nothing marked across the days this file covers.
  update,

  /// Already stored *and* already marked somewhere in those days, so bringing
  /// it in would write over what is there.
  overlap,
}

/// One occurrence resolved to the place its mark will go.
class NotionPlacement {
  const NotionPlacement({
    required this.row,
    required this.startMinutes,
    required this.scheduled,
    required this.weight,
  });

  final NotionRow row;
  final int startMinutes;

  /// What this occurrence will be written as. The grouping decides it, not
  /// the export — see [NotionGrouping].
  final int weight;

  /// Whether a class was actually on the timetable then. A placement that is
  /// not scheduled still counts — it lands as the orphaned mark the attendance
  /// log already knows how to show — but it is worth saying so first.
  final bool scheduled;
}

/// One subject the import would write, and everything known about it.
class NotionPlanSubject {
  NotionPlanSubject({
    required this.name,
    required this.code,
    required this.placements,
    required this.subject,
    required this.marksInRange,
  });

  final String name;

  /// The course code, where the components agree on one.
  final String? code;

  final List<NotionPlacement> placements;

  /// The stored subject this matched on name, if any.
  final Subject? subject;

  /// Marks already recorded here inside the export's date range.
  final int marksInRange;

  NotionMatch get match {
    if (subject == null) return NotionMatch.create;
    return marksInRange > 0 ? NotionMatch.overlap : NotionMatch.update;
  }

  int get classes => placements.length;

  int get unscheduled =>
      placements.where((NotionPlacement p) => !p.scheduled).length;

  bool get hasWeighted =>
      placements.any((NotionPlacement p) => p.weight != 1);

  int get suspect =>
      placements.where((NotionPlacement p) => p.row.creditDisagrees).length;

  int _periods(bool Function(NotionRow) test) => placements
      .where((NotionPlacement p) => test(p.row))
      .fold<int>(0, (int sum, NotionPlacement p) => sum + p.weight);

  int get present =>
      _periods((NotionRow r) => r.status == AttendanceStatus.present);

  int get absent =>
      _periods((NotionRow r) => r.status == AttendanceStatus.absent);

  int get cancelled =>
      _periods((NotionRow r) => r.status == AttendanceStatus.cancelled);

  /// How many classes carry each label the export used, "Proxy" and
  /// "Cancelled" among them, for the preview to say what is arriving.
  Map<String, int> get labels {
    final Map<String, int> counts = <String, int>{};
    for (final NotionPlacement p in placements) {
      final String? tag = p.row.tagName;
      if (tag != null) counts[tag] = (counts[tag] ?? 0) + 1;
    }
    return counts;
  }

  /// Held and attended in the same unit the subject will read in.
  int get held => present + absent;
  int get attended => present;
}

/// Every subject an export would write, resolved against what is stored.
class NotionPlan {
  const NotionPlan({required this.subjects, required this.grouping});

  final List<NotionPlanSubject> subjects;
  final NotionGrouping grouping;

  int countOf(NotionMatch match) =>
      subjects.where((NotionPlanSubject s) => s.match == match).length;

  int get classes => subjects.fold<int>(
        0,
        (int sum, NotionPlanSubject s) => sum + s.classes,
      );

  /// Builds the plan.
  ///
  /// [slots] is what turns a dated row into a placed mark: the export carries
  /// no time of day, and a mark is keyed by one. Matching against the
  /// timetable puts the mark on the real class rather than beside it.
  static NotionPlan from({
    required NotionExport export,
    required NotionGrouping grouping,
    required List<Subject> subjects,
    required List<ClassSlot> slots,
    required List<AttendanceRecord> records,
  }) {
    final Map<String, Subject> byName = <String, Subject>{
      for (final Subject s in subjects) s.name.trim().toLowerCase(): s,
    };

    final Map<String, List<NotionRow>> grouped = <String, List<NotionRow>>{};
    final Map<String, Set<String>> components = <String, Set<String>>{};
    for (final NotionRow row in export.rows) {
      final String name = grouping == NotionGrouping.grouped
          ? row.course
          : row.kind.subjectName(row.course);
      grouped.putIfAbsent(name, () => <NotionRow>[]).add(row);
      components.putIfAbsent(name, () => <String>{}).add(row.component);
    }

    final int from = Dates.keyOf(export.firstDate ?? Dates.today());
    final int to = Dates.keyOf(export.lastDate ?? Dates.today());

    final List<NotionPlanSubject> out = <NotionPlanSubject>[];
    for (final MapEntry<String, List<NotionRow>> entry in grouped.entries) {
      final Subject? existing = byName[entry.key.trim().toLowerCase()];
      final int? id = existing?.id;

      out.add(
        NotionPlanSubject(
          name: entry.key,
          code: _sharedCode(components[entry.key]!),
          subject: existing,
          marksInRange: id == null
              ? 0
              : records
                  .where((AttendanceRecord r) =>
                      r.subjectId == id &&
                      Dates.keyOf(r.date) >= from &&
                      Dates.keyOf(r.date) <= to)
                  .length,
          placements: _place(
            entry.value,
            slots.where((ClassSlot s) => s.subjectId == id).toList(),
            grouping,
          ),
        ),
      );
    }

    out.sort((NotionPlanSubject a, NotionPlanSubject b) =>
        a.name.compareTo(b.name));
    return NotionPlan(subjects: out, grouping: grouping);
  }

  /// The code the components agree on — `ABC101L` and `ABC101P` give `ABC101`.
  ///
  /// Null unless every component shares a prefix of at least three characters,
  /// since a made-up code on a subject card is worse than none.
  static String? _sharedCode(Set<String> components) {
    final List<String> names =
        components.where((String c) => c.isNotEmpty).toList()..sort();
    if (names.isEmpty) return null;
    if (names.length == 1) return names.first;

    String prefix = names.first;
    for (final String name in names.skip(1)) {
      int i = 0;
      while (i < prefix.length && i < name.length && prefix[i] == name[i]) {
        i++;
      }
      prefix = prefix.substring(0, i);
    }
    return prefix.length >= 3 ? prefix : null;
  }

  /// Gives every row a start time.
  ///
  /// Marks are keyed by `(subject, date, start)`, so two rows landing on the
  /// same minute would collapse into one and quietly lose a class. A row that
  /// brought its own time keeps it and is placed first, so the rows that did
  /// not cannot take a slot one of them already occupies. The rest take that
  /// day's scheduled start times in order, and anything left over falls back
  /// to an hour the day has not used yet.
  static List<NotionPlacement> _place(
    List<NotionRow> rows,
    List<ClassSlot> slots,
    NotionGrouping grouping,
  ) {
    final Map<int, List<NotionRow>> byDay = <int, List<NotionRow>>{};
    for (final NotionRow row in rows) {
      byDay.putIfAbsent(Dates.keyOf(row.date), () => <NotionRow>[]).add(row);
    }

    final List<NotionPlacement> out = <NotionPlacement>[];
    for (final List<NotionRow> day in byDay.values) {
      final List<int> free = slots
          .where((ClassSlot s) => s.appliesOn(day.first.date))
          .map((ClassSlot s) => s.startMinutes)
          .toList()
        ..sort();
      final Set<int> taken = <int>{};

      // Told beats inferred, and claiming those minutes up front is what stops
      // the inference below from handing the same slot to a second row.
      final List<NotionRow> told = <NotionRow>[
        for (final NotionRow r in day)
          if (r.startMinutes != null) r,
      ];
      for (final NotionRow row in told) {
        int start = row.startMinutes!;
        while (!taken.add(start)) {
          start = start + 1;
        }
        out.add(
          NotionPlacement(
            row: row,
            startMinutes: start,
            scheduled: free.contains(row.startMinutes),
            weight: grouping == NotionGrouping.grouped ? row.weight : 1,
          ),
        );
      }

      for (final NotionRow row in day) {
        if (row.startMinutes != null) continue;
        int? start;
        for (final int candidate in free) {
          if (taken.add(candidate)) {
            start = candidate;
            break;
          }
        }
        final bool scheduled = start != null;
        if (start == null) {
          // Nine in the morning, then the next free hour after it, so a day
          // with two unplaceable rows still keeps them apart.
          start = _fallbackStart;
          while (!taken.add(start!)) {
            start = start + 60;
          }
        }
        out.add(
          NotionPlacement(
            row: row,
            startMinutes: start,
            scheduled: scheduled,
            weight: grouping == NotionGrouping.grouped ? row.weight : 1,
          ),
        );
      }
    }

    out.sort((NotionPlacement a, NotionPlacement b) {
      final int byDate =
          Dates.keyOf(a.row.date).compareTo(Dates.keyOf(b.row.date));
      return byDate != 0 ? byDate : a.startMinutes.compareTo(b.startMinutes);
    });
    return out;
  }

  static const int _fallbackStart = 9 * 60;
}
