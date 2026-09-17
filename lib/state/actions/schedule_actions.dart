import 'dart:async';

import '../../core/date_utils.dart';
import '../../data/db/zeolite_repository.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/holiday.dart';
import '../../data/models/slot_override.dart';
import '../providers.dart';

/// The timetable itself: weekly rules, their exceptions, one-off classes and
/// holidays.
class ScheduleActions {
  ScheduleActions(this._core);

  final ActionCore _core;

  // recurring slots --------------------------------------------------------

  Future<void> addSlot(ClassSlot slot) async {
    await _core.repo.insertSlot(slot);
    await _core.refresh();
  }

  Future<void> updateSlot(ClassSlot slot) async {
    await _core.repo.updateSlot(slot);
    await _core.refresh();
  }

  /// Edits the rule and carries its marks across to the new
  /// `(subject, start time)`.
  ///
  /// The dates are kept. A mark records that a class happened on a day, and
  /// re-pointing the rule does not change which days were attended — only
  /// which class they belonged to. Marks already sitting at the destination
  /// are overwritten, since one occurrence can only hold one mark.
  Future<void> updateSlotAndMoveMarks(
    ClassSlot previous,
    ClassSlot updated,
  ) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    final List<AttendanceRecord> records =
        _core.ref.read(timetableProvider).value?.records ??
            <AttendanceRecord>[];
    await _core.repo.transaction((ZeoliteRepository repository) async {
      for (final AttendanceRecord record in records) {
        if (!previous.covers(record)) continue;
        await repository.clearAttendance(
          record.subjectId,
          record.date,
          record.startMinutes,
        );
        await repository.setAttendance(
          record.copyWith(
            subjectId: updated.subjectId,
            startMinutes: updated.startMinutes,
          ),
        );
      }
      await repository.updateSlot(updated);
    });
    await _core.refresh();
    _core.arm(before);
  }

  /// Deletes the rule and every future week it would have produced.
  ///
  /// Attendance already marked against it survives: marks are keyed by
  /// `(subject, date, start time)` and have no relationship to `class_slots`,
  /// so they keep counting and stay reachable in the subject's attendance log,
  /// flagged as orphaned.
  Future<void> deleteSlot(int id) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.deleteSlot(id);
    await _core.refresh();
    _core.arm(before);
  }

  /// Deletes the rule *and* the attendance recorded against it — the
  /// destructive half of the choice offered when a class is removed. Marks are
  /// matched by [ClassSlot.covers], having no slot id to follow.
  Future<void> deleteSlotAndMarks(ClassSlot slot) async {
    final int? id = slot.id;
    if (id == null) return;
    final DatabaseSnapshot before = await _core.repo.snapshot();
    final List<AttendanceRecord> records =
        _core.ref.read(timetableProvider).value?.records ??
            <AttendanceRecord>[];
    await _core.repo.transaction((ZeoliteRepository repository) async {
      for (final AttendanceRecord record in records) {
        if (!slot.covers(record)) continue;
        await repository.clearAttendance(
          record.subjectId,
          record.date,
          record.startMinutes,
        );
      }
      await repository.deleteSlot(id);
    });
    await _core.refresh();
    _core.arm(before);
  }

  /// Keeps history intact but stops the class recurring from [date] on.
  Future<void> endSlotFrom(int slotId, DateTime date) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.endSlotBefore(slotId, date);
    await _core.refresh();
    _core.arm(before);
  }

  /// Makes one week of [slot] differ from its rule, and moves that
  /// occurrence's mark if the change moved the attendance key.
  ///
  /// Empty fields inherit, so this writes only what actually changed. The
  /// override outlives a later edit to the rule on purpose: a day singled out
  /// by hand is a more specific statement than a bulk edit.
  Future<void> setSlotOverride(
    ClassSlot slot,
    DateTime date,
    SlotOverride override,
  ) async {
    final int? slotId = slot.id;
    if (slotId == null) return;
    final DatabaseSnapshot before = await _core.repo.snapshot();

    final ClassSlot was = _core.ref
            .read(timetableProvider)
            .value
            ?.overrideOn(slotId, date)
            ?.applyTo(slot) ??
        slot;
    final ClassSlot now = override.applyTo(slot) ?? slot;
    await _core.repo.transaction((ZeoliteRepository repository) async {
      await _moveMarkOn(date, was, now, repository);
      await repository.setSlotOverride(override);
    });
    await _core.refresh();
    _core.arm(before);
  }

  /// Removes one occurrence of [slot] and the mark recorded against it.
  Future<void> skipSlotOn(ClassSlot slot, DateTime date) async {
    final int? slotId = slot.id;
    if (slotId == null) return;
    final DatabaseSnapshot before = await _core.repo.snapshot();

    final ClassSlot shown = _core.ref
            .read(timetableProvider)
            .value
            ?.overrideOn(slotId, date)
            ?.applyTo(slot) ??
        slot;
    await _core.repo.transaction((ZeoliteRepository repository) async {
      await repository.clearAttendance(
        shown.subjectId,
        date,
        shown.startMinutes,
      );
      await repository.setSlotOverride(
        SlotOverride(slotId: slotId, date: date, skipped: true),
      );
    });
    await _core.refresh();
    _core.arm(before);
  }

  /// Carries a single occurrence's mark from one attendance key to another.
  ///
  /// Nothing happens when the key did not move, which is the common case: a
  /// room change leaves the mark exactly where it was filed.
  Future<void> _moveMarkOn(
    DateTime date,
    ClassSlot was,
    ClassSlot now,
    ZeoliteRepository repository,
  ) async {
    if (was.subjectId == now.subjectId &&
        was.startMinutes == now.startMinutes) {
      return;
    }
    final AttendanceRecord? mark = await repository.getAttendanceAt(
      was.subjectId,
      date,
      was.startMinutes,
    );
    if (mark == null) return;
    await repository.clearAttendance(was.subjectId, date, was.startMinutes);
    await repository.setAttendance(
      mark.copyWith(
        subjectId: now.subjectId,
        startMinutes: now.startMinutes,
      ),
    );
  }

  /// Ends the rule at [date] and clears what was recorded from that date on.
  ///
  /// The weeks before the cut keep their attendance, which is what this action
  /// has always been for. A mark on or after it belongs to an occurrence that
  /// is being removed, and follows its class out.
  Future<void> endSlotFromAndClearMarks(ClassSlot slot, DateTime date) async {
    final int? id = slot.id;
    if (id == null) return;
    final DatabaseSnapshot before = await _core.repo.snapshot();
    final List<AttendanceRecord> records =
        _core.ref.read(timetableProvider).value?.records ??
            <AttendanceRecord>[];
    final int cut = Dates.keyOf(date);
    await _core.repo.transaction((ZeoliteRepository repository) async {
      for (final AttendanceRecord record in records) {
        if (!slot.covers(record) || Dates.keyOf(record.date) < cut) continue;
        await repository.clearAttendance(
          record.subjectId,
          record.date,
          record.startMinutes,
        );
      }
      await repository.endSlotBefore(id, date);
    });
    await _core.refresh();
    _core.arm(before);
  }

  // one-off classes --------------------------------------------------------

  Future<void> addExtraClass(ExtraClass extra) async {
    await _core.repo.insertExtraClass(extra);
    await _core.refresh();
  }

  /// Moving a one-off class leaves any mark already made against it behind at
  /// the old `(subject, date, start time)`, exactly as editing a weekly rule
  /// does. The attendance log surfaces those as orphaned rather than deleting
  /// history the user did record.
  Future<void> updateExtraClass(ExtraClass extra) async {
    await _core.repo.updateExtraClass(extra);
    await _core.refresh();
  }

  /// Moves a one-off class and takes its mark with it.
  ///
  /// Unlike a weekly rule, a one-off *is* the single occurrence, so the mark
  /// follows the new date as well as the new subject and time.
  Future<void> updateExtraClassAndMoveMarks(
    ExtraClass previous,
    ExtraClass updated,
  ) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.transaction((ZeoliteRepository repository) async {
      final AttendanceRecord? record = await repository.getAttendanceAt(
        previous.subjectId,
        previous.date,
        previous.startMinutes,
      );
      if (record != null) {
        await repository.clearAttendance(
          previous.subjectId,
          previous.date,
          previous.startMinutes,
        );
        await repository.setAttendance(
          record.copyWith(
            subjectId: updated.subjectId,
            date: updated.date,
            startMinutes: updated.startMinutes,
          ),
        );
      }
      await repository.updateExtraClass(updated);
    });
    await _core.refresh();
    _core.arm(before);
  }

  Future<void> deleteExtraClass(int id) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.deleteExtraClass(id);
    await _core.refresh();
    _core.arm(before);
  }

  // holidays ---------------------------------------------------------------

  Future<void> addHoliday(Holiday holiday) async {
    await _core.repo.insertHoliday(holiday);
    await _core.refresh();
  }

  /// One refresh for the whole range — a two-week break would otherwise
  /// rebuild the engine, the day lists and the stats fourteen times.
  Future<void> addHolidays(List<Holiday> holidays) async {
    if (holidays.isEmpty) return;
    await _core.repo.insertHolidays(holidays);
    await _core.refresh();
  }

  Future<void> deleteHoliday(int id) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.deleteHoliday(id);
    await _core.refresh();
    _core.arm(before);
  }

  Future<void> deleteHolidays(List<int> ids) async {
    if (ids.isEmpty) return;
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.deleteHolidays(ids);
    await _core.refresh();
    _core.arm(before);
  }
}
