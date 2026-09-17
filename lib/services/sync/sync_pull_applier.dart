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
      semesterStart: _date(f['semesterStart']),
      semesterEnd: _date(f['semesterEnd']),
      targetPercent: _double(f['targetPercent']),
      defaultClassDurationMinutes: _int(f['defaultClassMinutes']),
      dayStartMinutes: _int(f['dayStartMinutes']),
      dayEndMinutes: _int(f['dayEndMinutes']),
      blockMinutes: _int(f['blockMinutes']),
      breakAfterBlock: _int(f['breakAfterBlock']),
      breakMinutes: _int(f['breakMinutes']),
      scheduleChangedAt: state.editedAt,
      // An account that knows its term has been set up, so a device joining
      // one must not ask again and save the answer over what this pull brought.
      onboarded: _date(f['semesterStart']) == null ? null : true,
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
      defaultDurationMinutes: _int(state.fields['defaultMinutes']) ??
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
      position: _int(state.fields['position']) ?? existing?.position ?? 0,
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
      position: _int(state.fields['position']) ?? existing?.position ?? 0,
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
    final int? dateKey = int.tryParse(state.localKey);
    final String? name = state.fields['name'] as String?;
    if (dateKey == null || name == null) return null;

    final Holiday? existing = local.holidayByKey[state.localKey];
    if (existing?.id != null) {
      await _repository.deleteHoliday(existing!.id!);
    }
    final Holiday holiday = Holiday(date: Dates.fromKey(dateKey), name: name);
    final int id = await _repository.insertHoliday(holiday);
    local.holidayByKey[state.localKey] =
        Holiday(id: id, date: holiday.date, name: holiday.name);
    return SyncItem.holiday(holiday);
  }

  Future<SyncItem?> _applySubject(
      RemoteState state, SyncLocalRows local) async {
    final Subject? existing = local.subjectByUuid[state.localKey];
    final Map<String, Object?> f = state.fields;
    final String? name = f['name'] as String?;
    if (name == null || name.isEmpty) return null;

    final String? categoryName = f['category'] as String?;
    final Subject subject = Subject(
      id: existing?.id,
      uuid: state.localKey,
      name: name,
      code: f['code'] as String?,
      teacher: f['teacher'] as String?,
      colorValue: _int(f['color']) ?? existing?.colorValue ?? 0xff607d8b,
      targetPercent: _double(f['targetPercent']),
      // Categories sync first, so a named one is already here unless the far
      // side never had it.
      categoryId:
          categoryName == null ? null : local.categoryByName[categoryName]?.id,
      // The row's own creation date survives a sync — only a subject arriving
      // for the first time has none of its own to keep.
      createdAt: existing?.createdAt ?? state.editedAt,
      updatedAt: state.editedAt,
      priorHeld: _int(f['priorHeld']) ?? 0,
      priorAttended: _int(f['priorAttended']) ?? 0,
      expectedTotal: _int(f['expectedTotal']),
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
    final String? subjectUuid = f['subject'] as String?;
    final Subject? subject =
        subjectUuid == null ? null : local.subjectByUuid[subjectUuid];
    final int? startDate = _int(f['startDate']);
    if (subject?.id == null || startDate == null) return null;

    final int? endDate = _int(f['endDate']);
    final ClassSlot? existing = local.slotByUuid[state.localKey];
    final ClassSlot slot = ClassSlot(
      id: existing?.id,
      uuid: state.localKey,
      subjectId: subject!.id!,
      weekday: _int(f['weekday']) ?? DateTime.monday,
      startMinutes: _int(f['startMinutes']) ?? 0,
      endMinutes: _int(f['endMinutes']) ?? 0,
      room: f['room'] as String?,
      weight: _int(f['weight']) ?? 1,
      startDate: Dates.fromKey(startDate),
      endDate: endDate == null ? null : Dates.fromKey(endDate),
    );

    if (existing == null) {
      final int id = await _repository.insertSlot(slot);
      local.slotByUuid[state.localKey] = slot.copyWith(id: id);
    } else {
      await _repository.updateSlot(slot);
      local.slotByUuid[state.localKey] = slot;
    }
    return SyncItem.slot(slot, subjectUuid!);
  }

  Future<SyncItem?> _applyExtraClass(
      RemoteState state, SyncLocalRows local) async {
    final Map<String, Object?> f = state.fields;
    final String? subjectUuid = f['subject'] as String?;
    final Subject? subject =
        subjectUuid == null ? null : local.subjectByUuid[subjectUuid];
    final int? date = _int(f['date']);
    if (subject?.id == null || date == null) return null;

    final ExtraClass? existing = local.extraByUuid[state.localKey];
    final ExtraClass extra = ExtraClass(
      id: existing?.id,
      uuid: state.localKey,
      subjectId: subject!.id!,
      date: Dates.fromKey(date),
      startMinutes: _int(f['startMinutes']) ?? 0,
      endMinutes: _int(f['endMinutes']) ?? 0,
      room: f['room'] as String?,
      weight: _int(f['weight']) ?? 1,
      note: f['note'] as String?,
    );

    if (existing == null) {
      final int id = await _repository.insertExtraClass(extra);
      local.extraByUuid[state.localKey] = extra.copyWith(id: id);
    } else {
      await _repository.updateExtraClass(extra);
      local.extraByUuid[state.localKey] = extra;
    }
    return SyncItem.extraClass(extra, subjectUuid!);
  }

  /// The rule has to be on this device already, which the coordinator's
  /// `_order` guarantees by pulling slots first: an exception to a rule
  /// nothing here holds has no id to store against and no occurrence to
  /// change.
  Future<SyncItem?> _applySlotOverride(
      RemoteState state, SyncLocalRows local) async {
    final _OverrideKey? key = _OverrideKey.parse(state.localKey);
    final ClassSlot? slot = key == null ? null : local.slotByUuid[key.slotUuid];
    if (key == null || slot?.id == null) return null;

    final Map<String, Object?> f = state.fields;
    final String? subjectUuid = f['subject'] as String?;
    final int? subjectId =
        subjectUuid == null ? null : local.subjectByUuid[subjectUuid]?.id;

    final SlotOverride override = SlotOverride(
      uuid: local.overrideByKey[state.localKey]?.uuid,
      slotId: slot!.id!,
      date: key.date,
      skipped: f['skipped'] == true,
      subjectId: subjectId,
      startMinutes: _int(f['startMinutes']),
      endMinutes: _int(f['endMinutes']),
      room: f['room'] as String?,
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
    final Subject? subject = key == null ? null : local.subjectByUuid[key.uuid];
    // A mark for a subject this device has never heard of. Subjects sync
    // first, so the only way here is a subject that failed to apply; the row
    // stays unlinked and the next run offers it again.
    if (key == null || subject?.id == null) return null;

    final AttendanceStatus? status =
        AttendanceStatus.fromName(state.fields['status'] as String?);
    if (status == null) return null;

    final String? tagName = state.fields['tag'] as String?;
    final AttendanceRecord record = AttendanceRecord(
      subjectId: subject!.id!,
      date: key.date,
      startMinutes: key.startMinutes,
      status: status,
      weight: _int(state.fields['weight']) ?? 1,
      tagId: tagName == null ? null : local.tagByName[tagName]?.id,
      note: state.fields['note'] as String?,
      markedAt: state.editedAt,
    );
    await _repository.setAttendance(record);
    return SyncItem.attendance(record, key.uuid, tagName: tagName);
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
    final int? dateKey = int.tryParse(parts[1]);
    if (parts[0].isEmpty || dateKey == null) return null;
    return _OverrideKey(parts[0], Dates.fromKey(dateKey));
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
    final int? dateKey = int.tryParse(parts[1]);
    final int? start = int.tryParse(parts[2]);
    if (parts[0].isEmpty || dateKey == null || start == null) return null;
    return _MarkKey(parts[0], Dates.fromKey(dateKey), start);
  }
}

int? _int(Object? value) => switch (value) {
      int v => v,
      num v => v.round(),
      String v => int.tryParse(v),
      _ => null,
    };

/// A day key back to a date. Null stays null, so a semester end that has not
/// been set travels as "not set" rather than as an epoch.
DateTime? _date(Object? value) {
  final int? key = _int(value);
  return key == null ? null : Dates.fromKey(key);
}

double? _double(Object? value) => switch (value) {
      num v => v.toDouble(),
      String v => double.tryParse(v),
      _ => null,
    };
