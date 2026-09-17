import 'dart:async';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/db/zeolite_repository.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/room.dart';
import '../../data/models/subject.dart';
import '../../data/models/tag.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_totals_import.dart';
import '../../domain/attendance_totals_ocr.dart';
import '../../domain/class_weight.dart';
import '../../domain/notion_import.dart';
import '../../domain/timetable_import.dart';
import '../providers.dart';

/// The bulk writes: a pasted timetable, a portal's totals, a Notion log, and
/// re-weighting a term from its categories. Each one sits under a single Undo
/// snapshot.
class ImportActions {
  ImportActions(this._core);

  final ActionCore _core;

  /// Writes a parsed paste as subjects and weekly classes.
  ///
  /// A subject already on the timetable is matched by name and reused, so a
  /// second paste extends it rather than creating a twin that would split the
  /// attendance percentage in two.
  /// Additive, so nothing here destroys data — but ten subjects and twenty-one
  /// classes arrive in one tap, and taking them back out again is a delete per
  /// subject. That asymmetry is what the snapshot is for.
  /// [weighByBlocks] gives a class that fills two blocks a weight of two, for
  /// an institution that counts it that way. Off by default, so a paste
  /// behaves exactly as it always has unless the user asks.
  Future<void> importTimetable(
    TimetableImportResult result, {
    bool weighByBlocks = false,
  }) async {
    final TimetableData? data = _core.ref.read(timetableProvider).value;
    if (data == null || result.classes.isEmpty) return;

    final DatabaseSnapshot before = await _core.repo.snapshot();

    final Map<String, int> idByName = <String, int>{
      for (final Subject subject in data.subjects)
        if (subject.id != null) subject.name.trim().toLowerCase(): subject.id!,
    };

    final List<String> fresh = result.subjectNames
        .where((String name) => !idByName.containsKey(name.toLowerCase()))
        .toList();

    final DateTime start =
        _core.ref.read(settingsProvider).value?.semesterStart ?? Dates.today();
    final Set<String> known =
        data.rooms.map((Room room) => room.name.toLowerCase()).toSet();

    await _core.repo.transaction((ZeoliteRepository repository) async {
      final List<int> palette = AppColors.subjectPalette;
      final List<int> ids = await repository.insertSubjects(<Subject>[
        for (int i = 0; i < fresh.length; i++)
          Subject(
            name: fresh[i],
            teacher: _teacherFor(result, fresh[i]),
            colorValue: palette[(data.subjects.length + i) % palette.length],
          ),
      ]);
      for (int i = 0; i < fresh.length; i++) {
        idByName[fresh[i].toLowerCase()] = ids[i];
      }

      await repository.insertSlots(<ClassSlot>[
        for (final ImportedClass c in result.classes)
          ClassSlot(
            subjectId: idByName[c.subjectKey]!,
            weekday: c.weekday,
            startMinutes: c.startMinutes,
            endMinutes: c.endMinutes,
            room: c.room,
            weight: weighByBlocks ? c.blocks : 1,
            startDate: start,
          ),
      ]);

      for (final String room in result.roomNames) {
        if (known.add(room.toLowerCase())) {
          await repository.insertRoom(Room(name: room));
        }
      }
    });

    await _core.refresh();
    _core.arm(before);
    unawaited(_core.analytics.timetableImported('paste'));
  }

  /// Brings every class and every mark into line with what its subject's
  /// category now says a class is worth.
  ///
  /// The only place the rule is applied backwards — everywhere else it merely
  /// seeds, because a mark carries what it was worth when it was made. So the
  /// user asks for this, under one snapshot, and one Undo puts a term back.
  ///
  /// A weight set by hand on one class is replaced: the category is now the
  /// authority. Returns how many marks actually moved.
  Future<int> applyClassWeights() async {
    final TimetableData? data = _core.ref.read(timetableProvider).value;
    if (data == null) return 0;

    final DatabaseSnapshot before = await _core.repo.snapshot();

    int weightOf(int subjectId) =>
        weightFor(data.categoryFor(data.subjectById(subjectId)));

    final int changedCount = await _core.repo.transaction(
      (ZeoliteRepository repository) async {
        for (final ClassSlot slot in data.slots) {
          final int weight = weightOf(slot.subjectId);
          if (slot.weight != weight) {
            await repository.updateSlot(slot.copyWith(weight: weight));
          }
        }
        for (final ExtraClass extra in data.extras) {
          final int weight = weightOf(extra.subjectId);
          if (extra.weight != weight) {
            await repository.updateExtraClass(extra.copyWith(weight: weight));
          }
        }

        // Read fresh rather than off [TimetableData]: a mark outside the term
        // window is still a mark, and leaving it on the old rule would make
        // the figures disagree the moment the window moved.
        final List<AttendanceRecord> stored = await repository.getAttendance();
        final List<AttendanceRecord> changed = <AttendanceRecord>[
          for (final AttendanceRecord record in stored)
            if (record.weight != weightOf(record.subjectId))
              record.copyWith(weight: weightOf(record.subjectId)),
        ];
        await repository.setManyAttendance(changed);
        return changed.length;
      },
    );

    await _core.refresh();
    _core.arm(before);
    return changedCount;
  }

  /// Writes a portal's per-subject figures onto the subjects they name.
  ///
  /// Additive in the same way the paste import is: a row the user left out of
  /// [decisions] is not touched at all, and the whole thing sits under one undo
  /// snapshot. [TotalsDecision.clearMarks] drops that subject's term marks
  /// first, for the reason given on [TotalsMatch.overlap].
  Future<int> importAttendanceTotals(List<TotalsDecision> decisions) async {
    final TimetableData? data = _core.ref.read(timetableProvider).value;
    if (data == null || decisions.isEmpty) return 0;

    final DatabaseSnapshot before = await _core.repo.snapshot();
    final AppSettings settings =
        _core.ref.read(settingsProvider).value ?? const AppSettings();
    final List<int> palette = AppColors.subjectPalette;

    await _core.repo.transaction((ZeoliteRepository repository) async {
      int created = 0;
      for (final TotalsDecision decision in decisions) {
        final TotalsRow row = decision.row;
        final int? id = decision.subjectId;
        if (id == null) {
          await repository.insertSubject(
            Subject(
              name: row.subject,
              colorValue:
                  palette[(data.subjects.length + created) % palette.length],
              priorHeld: row.held,
              priorAttended: row.attended,
              expectedTotal: row.expectedTotal,
            ),
          );
          created++;
          continue;
        }

        if (decision.clearMarks) {
          // The window has to match what [AppSettings.countsInTerm] counts, or
          // the marks the preview weighed are not the marks that go: with no
          // dates set everything counts, so everything goes.
          await repository.clearAttendanceBetween(
            id,
            settings.semesterStart ?? DateTime.utc(1970),
            settings.semesterEnd ?? DateTime.utc(2999),
          );
        }
        final Subject? existing =
            data.subjects.where((Subject s) => s.id == id).firstOrNull;
        // Gone since the preview was built, so there is nothing to write onto.
        if (existing == null) continue;
        await repository.updateSubject(
          existing.copyWith(
            priorHeld: row.held,
            priorAttended: row.attended,
            expectedTotal: row.expectedTotal,
          ),
        );
      }
    });

    await _core.refresh();
    _core.arm(before);
    unawaited(_core.analytics.timetableImported('totals'));
    return decisions.length;
  }

  /// Writes a Notion class log as marks against the subjects it names.
  ///
  /// Additive like the other two imports: a subject the user unticked is not
  /// touched. A [NotionMatch.overlap] subject has its marks inside the
  /// export's own span cleared first — the export is the whole truth for those
  /// dates, so keeping both would double the term.
  Future<int> importNotionLog(List<NotionPlanSubject> chosen) async {
    final TimetableData? data = _core.ref.read(timetableProvider).value;
    if (data == null || chosen.isEmpty) return 0;

    final DatabaseSnapshot before = await _core.repo.snapshot();
    final List<int> palette = AppColors.subjectPalette;

    // A tag per label the file actually uses, matched against the user's own
    // list first so an import never makes a second "Proxy".
    final Map<String, int> tagIds = <String, int>{};
    final List<AttendanceRecord> records = <AttendanceRecord>[];
    await _core.repo.transaction((ZeoliteRepository repository) async {
      for (final NotionPlanSubject planned in chosen) {
        for (final NotionPlacement placed in planned.placements) {
          final String? name = placed.row.tagName;
          if (name == null || tagIds.containsKey(name)) continue;
          final Tag? existing = data.tags
              .where(
                (Tag tag) =>
                    tag.name.trim().toLowerCase() == name.toLowerCase(),
              )
              .firstOrNull;
          tagIds[name] =
              existing?.id ?? await repository.insertTag(Tag(name: name));
        }
      }

      int created = 0;
      for (final NotionPlanSubject planned in chosen) {
        if (planned.placements.isEmpty) continue;

        int? id = planned.subject?.id;
        if (id == null) {
          id = await repository.insertSubject(
            Subject(
              name: planned.name,
              code: planned.code,
              colorValue:
                  palette[(data.subjects.length + created) % palette.length],
            ),
          );
          created++;
        } else if (planned.match == NotionMatch.overlap) {
          final List<DateTime> dates = planned.placements
              .map((NotionPlacement placement) => placement.row.date)
              .toList()
            ..sort();
          await repository.clearAttendanceBetween(id, dates.first, dates.last);
        }

        for (final NotionPlacement placed in planned.placements) {
          records.add(
            AttendanceRecord(
              subjectId: id,
              date: placed.row.date,
              startMinutes: placed.startMinutes,
              status: placed.row.status,
              weight: placed.weight,
              tagId: tagIds[placed.row.tagName],
              markedAt: DateTime.now(),
            ),
          );
        }
      }

      await repository.setManyAttendance(records);
    });
    await _core.refresh();
    _core.arm(before);
    unawaited(_core.analytics.timetableImported('notion'));
    return records.length;
  }

  /// The first teacher named against the subject anywhere in the paste. A
  /// timetable repeats it on every row, and disagreeing rows are the printer's
  /// problem rather than something to resolve here.
  static String? _teacherFor(TimetableImportResult result, String name) {
    final String key = name.trim().toLowerCase();
    for (final ImportedClass c in result.classes) {
      if (c.subjectKey == key && c.teacher != null) return c.teacher;
    }
    return null;
  }
}
