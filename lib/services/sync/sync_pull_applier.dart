import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';
import '../../data/db/zeolite_repository.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/class_category.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/holiday.dart';
import '../../data/models/room.dart';
import '../../data/models/slot_override.dart';
import '../../data/models/subject.dart';
import '../../data/models/tag.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/sync/sync_plan.dart';
import '../../domain/sync/sync_target.dart';

import 'remote_fields.dart';
import 'sync_local_rows.dart';

/// Writes what the far side holds into the local database, one row at a time,
/// for [SyncCoordinator].
class SyncPullApplier {
  SyncPullApplier({
    required ZeoliteRepository repository,
    required SettingsService settings,
    required SyncTarget target,
    required DateTime Function() now,
  })  : _repository = repository,
        _settings = settings,
        _target = target,
        _now = now;

  final ZeoliteRepository _repository;
  final SettingsService _settings;
  final SyncTarget _target;
  final DateTime Function() _now;

  /// Writes one remote row into the database, returning the link to record —
  /// or null when the row was a tombstone, where the link goes instead of
  /// being updated to describe something neither side holds.
  Future<RemoteLink?> apply(
    SyncPull pull,
    SyncKind kind,
    SyncLocalRows local,
  ) async {
    final RemoteState state = pull.remote;
    if (state.deleted) {
      await _deleteLocal(kind, state.localKey, local);
      return null;
    }

    final SyncItem? applied = switch (kind) {
      SyncKind.settings => await _applySettings(state),
      SyncKind.category => await _applyCategory(state, local),
      SyncKind.room => await _applyRoom(state, local),
      SyncKind.tag => await _applyTag(state, local),
      SyncKind.holiday => await _applyHoliday(state, local),
      SyncKind.subject => await _applySubject(state, local),
      SyncKind.slot => await _applySlot(state, local),
      SyncKind.extraClass => await _applyExtraClass(state, local),
      SyncKind.slotOverride => await _applySlotOverride(state, local),
      SyncKind.attendance => await _applyAttendance(state, local),
    };
    if (applied == null) return null;

    return RemoteLink(
      id: pull.link?.id,
      target: _target.id,
      kind: kind,
      localKey: state.localKey,
      remoteId: state.remoteId,
      // Taken from what was actually written rather than from the remote hash:
      // anything the local row cannot hold has to show as a difference on the
      // next run, not be papered over here.
      localHash: applied.hash,
      remoteHash: state.hash,
      origin: pull.link?.origin ?? SyncOrigin.remote,
      syncedAt: _now(),
    );
  }

  /// Merged field by field rather than replacing the object, so the settings
  /// that never travel — theme, notifications, the backup folder — survive a
  /// pull from a device that has different ones.
  Future<SyncItem?> _applySettings(RemoteState state) async {
    final Map<String, Object?> f = state.fields;
    final AppSettings current = await _settings.load();

    final AppSettings merged = current.copyWith(
      semesterStart: readDay(f['semesterStart']),
      semesterEnd: readDay(f['semesterEnd']),
      targetPercent: readDouble(f['targetPercent']),
      defaultClassDurationMinutes: readInt(f['defaultClassMinutes']),
      dayStartMinutes: readInt(f['dayStartMinutes']),
      dayEndMinutes: readInt(f['dayEndMinutes']),
      blockMinutes: readInt(f['blockMinutes']),
      breakAfterBlock: readInt(f['breakAfterBlock']),
      breakMinutes: readInt(f['breakMinutes']),
      scheduleChangedAt: state.editedAt,
      // An account that knows its term has been set up, so a device joining
      // one must not ask again and save the answer over what this pull brought.
      onboarded: readDay(f['semesterStart']) == null ? null : true,
    );
    await _settings.save(merged);
    return SyncItem.settings(merged, changedAt: merged.scheduleChangedAt);
  }

  Future<SyncItem?> _applyCategory(
      RemoteState state, SyncLocalRows local) async {
    final ClassCategory? existing = local.categoryByName[state.localKey];
    final ClassCategory category = ClassCategory(
      id: existing?.id,
      name: state.localKey,
      defaultDurationMinutes: readInt(state.fields['defaultMinutes']) ??
          existing?.defaultDurationMinutes ??
          60,
      createdAt: state.editedAt ?? existing?.createdAt,
    );

    if (existing == null) {
      final int id = await _repository.insertCategory(category);
      local.categoryByName[state.localKey] = ClassCategory(
        id: id,
        name: category.name,
        defaultDurationMinutes: category.defaultDurationMinutes,
        createdAt: category.createdAt,
      );
    } else {
      await _repository.updateCategory(category);
      local.categoryByName[state.localKey] = category;
    }
    return SyncItem.category(category);
  }

  Future<SyncItem?> _applyRoom(RemoteState state, SyncLocalRows local) async {
    final Room? existing = local.roomByName[state.localKey];
    final Room room = Room(
      id: existing?.id,
      name: state.localKey,
      position: readInt(state.fields['position']) ?? existing?.position ?? 0,
    );

    if (existing == null) {
      final int id = await _repository.insertRoom(room);
      local.roomByName[state.localKey] =
          Room(id: id, name: room.name, position: room.position);
    } else {
      await _repository.updateRoom(room);
      local.roomByName[state.localKey] = room;
    }
    return SyncItem.room(room);
  }

  Future<SyncItem?> _applyTag(RemoteState state, SyncLocalRows local) async {
    final Tag? existing = local.tagByName[state.localKey];
    final Tag tag = Tag(
      id: existing?.id,
      name: state.localKey,
      position: readInt(state.fields['position']) ?? existing?.position ?? 0,
    );

    if (existing == null) {
      final int id = await _repository.insertTag(tag);
      local.tagByName[state.localKey] =
          Tag(id: id, name: tag.name, position: tag.position);
    } else {
      await _repository.updateTag(tag);
      local.tagByName[state.localKey] = tag;
    }
    return SyncItem.tag(tag);
  }

  /// The date is the key and the table already makes it unique, so a pulled
  /// holiday is replaced rather than updated — there is no other field that
  /// could have moved.
  Future<SyncItem?> _applyHoliday(
      RemoteState state, SyncLocalRows local) async {
    final DateTime? date = readDay(state.localKey);
    final String? name = readString(state.fields['name']);
    if (date == null || name == null) throw UnreadableRow(state.localKey);

    final Holiday? existing = local.holidayByKey[state.localKey];
    if (existing?.id != null) {
      await _repository.deleteHoliday(existing!.id!);
    }
    final Holiday holiday = Holiday(date: date, name: name);
    final int id = await _repository.insertHoliday(holiday);
    local.holidayByKey[state.localKey] =
        Holiday(id: id, date: holiday.date, name: holiday.name);
    return SyncItem.holiday(holiday);
  }

  Future<SyncItem?> _applySubject(
      RemoteState state, SyncLocalRows local) async {
    final Subject? existing = local.subjectByUuid[state.localKey];
    final Map<String, Object?> f = state.fields;
    final String? name = readString(f['name']);
    if (name == null || name.isEmpty) throw UnreadableRow(state.localKey);

    final String? categoryName = readString(f['category']);
    final Subject subject = Subject(
      id: existing?.id,
      uuid: state.localKey,
      name: name,
      code: readString(f['code']),
      teacher: readString(f['teacher']),
      colorValue: readInt(f['color']) ?? existing?.colorValue ?? 0xff607d8b,
      targetPercent: readDouble(f['targetPercent']),
      // Categories sync first, so a named one is already here unless the far
      // side never had it.
      categoryId:
          categoryName == null ? null : local.categoryByName[categoryName]?.id,
      // The row's own creation date survives a sync — only a subject arriving
      // for the first time has none of its own to keep.
      createdAt: existing?.createdAt ?? state.editedAt,
      updatedAt: state.editedAt,
      priorHeld: readInt(f['priorHeld']) ?? 0,
      priorAttended: readInt(f['priorAttended']) ?? 0,
      expectedTotal: readInt(f['expectedTotal']),
    );

    if (existing == null) {
      final int id = await _repository.insertSubject(subject);
      local.subjectByUuid[state.localKey] = subject.copyWith(id: id);
    } else {
      await _repository.updateSubject(subject, touch: false);
      local.subjectByUuid[state.localKey] = subject;
    }
    return SyncItem.subject(subject, categoryName: categoryName);
  }

  Future<SyncItem?> _applySlot(RemoteState state, SyncLocalRows local) async {
    final Map<String, Object?> f = state.fields;
    final String? subjectUuid = readString(f['subject']);
    final Subject? subject =
        subjectUuid == null ? null : local.subjectByUuid[subjectUuid];
    if (subject?.id == null) return null;

    final DateTime? startDate = readDay(f['startDate']);
    final DateTime? endDate = readDay(f['endDate']);
    final int? weekday = readInt(f['weekday']);
    final int? start = readInt(f['startMinutes']);
    final int? end = readInt(f['endMinutes']);
    // An end date that is there but unreadable must not become "repeats for
    // ever", which is what a null one means.
    if (startDate == null ||
        (f['endDate'] != null && endDate == null) ||
        weekday == null ||
        weekday < DateTime.monday ||
        weekday > DateTime.sunday ||
        !isClassTime(start, end)) {
      throw UnreadableRow(state.localKey);
    }

    final ClassSlot? existing = local.slotByUuid[state.localKey];
    final ClassCategory? type = _typeOf(f, local);
    final ClassSlot slot = ClassSlot(
      id: existing?.id,
      uuid: state.localKey,
      subjectId: subject!.id!,
      weekday: weekday,
      startMinutes: start!,
      endMinutes: end!,
      room: readString(f['room']),
      weight: readInt(f['weight']) ?? 1,
      categoryId: type?.id,
      startDate: startDate,
      endDate: endDate,
    );

    if (existing == null) {
      final int id = await _repository.insertSlot(slot);
      local.slotByUuid[state.localKey] = slot.copyWith(id: id);
    } else {
      await _repository.updateSlot(slot);
      local.slotByUuid[state.localKey] = slot;
    }
    return SyncItem.slot(slot, subjectUuid!, categoryName: type?.name);
  }

  /// A class's own type, by name. Only one that resolved is reported back: a
  /// type this device does not have was not written, and the hash has to say
  /// so for the difference to surface again once it arrives.
  static ClassCategory? _typeOf(
    Map<String, Object?> fields,
    SyncLocalRows local,
  ) {
    final String? name = readString(fields['category']);
    final ClassCategory? type = name == null ? null : local.categoryByName[name];
    return type?.id == null ? null : type;
  }

  Future<SyncItem?> _applyExtraClass(
      RemoteState state, SyncLocalRows local) async {
    final Map<String, Object?> f = state.fields;
    final String? subjectUuid = readString(f['subject']);
    final Subject? subject =
        subjectUuid == null ? null : local.subjectByUuid[subjectUuid];
    if (subject?.id == null) return null;

    final DateTime? date = readDay(f['date']);
    final int? start = readInt(f['startMinutes']);
    final int? end = readInt(f['endMinutes']);
    if (date == null || !isClassTime(start, end)) {
      throw UnreadableRow(state.localKey);
    }

    final ExtraClass? existing = local.extraByUuid[state.localKey];
    final ClassCategory? type = _typeOf(f, local);
    final ExtraClass extra = ExtraClass(
      id: existing?.id,
      uuid: state.localKey,
      subjectId: subject!.id!,
      date: date,
      startMinutes: start!,
      endMinutes: end!,
      room: readString(f['room']),
      weight: readInt(f['weight']) ?? 1,
      categoryId: type?.id,
      note: readString(f['note']),
    );

    if (existing == null) {
      final int id = await _repository.insertExtraClass(extra);
      local.extraByUuid[state.localKey] = extra.copyWith(id: id);
    } else {
      await _repository.updateExtraClass(extra);
      local.extraByUuid[state.localKey] = extra;
    }
    return SyncItem.extraClass(extra, subjectUuid!, categoryName: type?.name);
  }

  /// The rule has to be on this device already, which the coordinator's
  /// `_order` guarantees by pulling slots first: an exception to a rule
  /// nothing here holds has no id to store against and no occurrence to
  /// change.
  Future<SyncItem?> _applySlotOverride(
      RemoteState state, SyncLocalRows local) async {
    final _OverrideKey? key = _OverrideKey.parse(state.localKey);
    if (key == null) throw UnreadableRow(state.localKey);
    final ClassSlot? slot = local.slotByUuid[key.slotUuid];
    if (slot?.id == null) return null;

    final Map<String, Object?> f = state.fields;
    final int? start = readInt(f['startMinutes']);
    final int? end = readInt(f['endMinutes']);
    // Either may be absent, which means the rule's own time carries through.
    final bool startOk = f['startMinutes'] == null || isMinuteOfDay(start);
    final bool endOk = f['endMinutes'] == null ||
        (end != null && end > 0 && end <= Clock.minutesPerDay);
    if (!startOk || !endOk || (start != null && end != null && end <= start)) {
      throw UnreadableRow(state.localKey);
    }
    final String? subjectUuid = readString(f['subject']);
    final int? subjectId =
        subjectUuid == null ? null : local.subjectByUuid[subjectUuid]?.id;

    final SlotOverride override = SlotOverride(
      uuid: local.overrideByKey[state.localKey]?.uuid,
      slotId: slot!.id!,
      date: key.date,
      skipped: f['skipped'] == true,
      subjectId: subjectId,
      startMinutes: start,
      endMinutes: end,
      room: readString(f['room']),
    );

    // A row that changes nothing is not stored, so there is no link to keep
    // either — returning null drops it rather than pointing it at an absence.
    if (override.isEmpty) {
      await _repository.clearSlotOverride(slot.id!, key.date);
      local.overrideByKey.remove(state.localKey);
      return null;
    }

    await _repository.setSlotOverride(override);
    local.overrideByKey[state.localKey] = override;
    return SyncItem.slotOverride(
      override,
      key.slotUuid,
      // Only when it resolved: a subject this device does not have was not
      // written, and the hash has to say so or the difference never resurfaces.
      subjectUuid: subjectId == null ? null : subjectUuid,
    );
  }

  Future<SyncItem?> _applyAttendance(
      RemoteState state, SyncLocalRows local) async {
    final _MarkKey? key = _MarkKey.parse(state.localKey);
    if (key == null) throw UnreadableRow(state.localKey);
    final Subject? subject = local.subjectByUuid[key.uuid];
    // A mark for a subject this device has never heard of. Subjects sync
    // first, so the only way here is a subject that failed to apply; the row
    // stays unlinked and the next run offers it again.
    if (subject?.id == null) return null;

    final AttendanceStatus? status =
        AttendanceStatus.fromName(readString(state.fields['status']));
    if (status == null) throw UnreadableRow(state.localKey);

    final String? tagName = readString(state.fields['tag']);
    final ClassCategory? type = _typeOf(state.fields, local);
    final AttendanceRecord record = AttendanceRecord(
      subjectId: subject!.id!,
      date: key.date,
      startMinutes: key.startMinutes,
      status: status,
      weight: readInt(state.fields['weight']) ?? 1,
      categoryId: type?.id,
      tagId: tagName == null ? null : local.tagByName[tagName]?.id,
      note: readString(state.fields['note']),
      markedAt: state.editedAt,
    );
    await _repository.setAttendance(record);
    return SyncItem.attendance(
      record,
      key.uuid,
      tagName: tagName,
      categoryName: type?.name,
    );
  }

  Future<void> _deleteLocal(
    SyncKind kind,
    String localKey,
    SyncLocalRows local,
  ) async {
    switch (kind) {
      // The row always exists, and clearing the semester dates because another
      // device stopped holding them is not a deletion anyone asked for.
      case SyncKind.settings:
        return;
      case SyncKind.category:
        final ClassCategory? category = local.categoryByName.remove(localKey);
        if (category?.id != null) {
          await _repository.deleteCategory(category!.id!);
        }
      case SyncKind.room:
        final Room? room = local.roomByName.remove(localKey);
        if (room?.id != null) await _repository.deleteRoom(room!.id!);
      case SyncKind.tag:
        final Tag? tag = local.tagByName.remove(localKey);
        if (tag?.id != null) await _repository.deleteTag(tag!.id!);
      case SyncKind.holiday:
        final Holiday? holiday = local.holidayByKey.remove(localKey);
        if (holiday?.id != null) {
          await _repository.deleteHoliday(holiday!.id!);
        }
      case SyncKind.subject:
        final Subject? subject = local.subjectByUuid.remove(localKey);
        if (subject?.id != null) await _repository.deleteSubject(subject!.id!);
      case SyncKind.slot:
        final ClassSlot? slot = local.slotByUuid.remove(localKey);
        if (slot?.id != null) await _repository.deleteSlot(slot!.id!);
      case SyncKind.extraClass:
        final ExtraClass? extra = local.extraByUuid.remove(localKey);
        if (extra?.id != null) await _repository.deleteExtraClass(extra!.id!);
      case SyncKind.slotOverride:
        final _OverrideKey? key = _OverrideKey.parse(localKey);
        final ClassSlot? slot =
            key == null ? null : local.slotByUuid[key.slotUuid];
        if (key == null || slot?.id == null) return;
        local.overrideByKey.remove(localKey);
        await _repository.clearSlotOverride(slot!.id!, key.date);
      case SyncKind.attendance:
        final _MarkKey? key = _MarkKey.parse(localKey);
        final Subject? subject =
            key == null ? null : local.subjectByUuid[key.uuid];
        if (key == null || subject?.id == null) return;
        await _repository.clearAttendance(
          subject!.id!,
          key.date,
          key.startMinutes,
        );
    }
  }
}

/// The three parts of an attendance sync key, back out of the string.
@immutable
class _OverrideKey {
  const _OverrideKey(this.slotUuid, this.date);

  final String slotUuid;
  final DateTime date;

  static _OverrideKey? parse(String key) {
    final List<String> parts = key.split(':');
    if (parts.length != 2) return null;
    final DateTime? date = readDay(parts[1]);
    if (parts[0].isEmpty || date == null) return null;
    return _OverrideKey(parts[0], date);
  }
}

class _MarkKey {
  const _MarkKey(this.uuid, this.date, this.startMinutes);

  final String uuid;
  final DateTime date;
  final int startMinutes;

  static _MarkKey? parse(String key) {
    final List<String> parts = key.split(':');
    if (parts.length != 3) return null;
    final DateTime? date = readDay(parts[1]);
    final int? start = int.tryParse(parts[2]);
    if (parts[0].isEmpty || date == null || !isMinuteOfDay(start)) {
      return null;
    }
    return _MarkKey(parts[0], date, start!);
  }
}
