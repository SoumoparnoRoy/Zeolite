import '../../core/date_utils.dart';
import '../../data/db/zeolite_repository.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/class_category.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/holiday.dart';
import '../../data/models/room.dart';
import '../../data/models/slot_override.dart';
import '../../data/models/subject.dart';
import '../../data/models/tag.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/sync/sync_target.dart';

/// Every lookup a pull needs to turn a far-side key back into a local row.
///
/// Mutable, and updated as rows are applied: a slot arriving in the same run
/// as the subject it names has to find it.
class SyncLocalRows {
  SyncLocalRows({
    required this.subjectByUuid,
    required this.categoryByName,
    required this.roomByName,
    required this.tagByName,
    required this.holidayByKey,
    required this.slotByUuid,
    required this.extraByUuid,
    required this.overrideByKey,
  });

  final Map<String, Subject> subjectByUuid;
  final Map<String, ClassCategory> categoryByName;
  final Map<String, Room> roomByName;
  final Map<String, Tag> tagByName;
  final Map<String, Holiday> holidayByKey;
  final Map<String, ClassSlot> slotByUuid;
  final Map<String, ExtraClass> extraByUuid;
  final Map<String, SlotOverride> overrideByKey;

  final Map<SyncKind, List<SyncItem>> items = <SyncKind, List<SyncItem>>{};

  /// The local side of a run, read once. A row whose parent has no key is left
  /// out entirely rather than sent under a local id — a subject with no uuid
  /// takes its marks and its slots down with it.
  static Future<SyncLocalRows> read(
    ZeoliteRepository repository,
    SettingsService settingsService,
  ) async {
    final List<Subject> subjects = await repository.getSubjects();
    final List<ClassCategory> categories = await repository.getCategories();
    final List<Room> rooms = await repository.getRooms();
    final List<Tag> tags = await repository.getTags();
    final List<Holiday> holidays = await repository.getHolidays();
    final List<ClassSlot> slots = await repository.getSlots();
    final List<ExtraClass> extras = await repository.getExtraClasses();
    final List<SlotOverride> overrides = await repository.getSlotOverrides();
    final AppSettings settings = await settingsService.load();

    final Map<int, String> uuidById = <int, String>{
      for (final Subject s in subjects)
        if (s.id != null && s.uuid != null) s.id!: s.uuid!,
    };
    final Map<int, String> slotUuidById = <int, String>{
      for (final ClassSlot s in slots)
        if (s.id != null && s.uuid != null) s.id!: s.uuid!,
    };
    final Map<int, String> categoryNameById = <int, String>{
      for (final ClassCategory c in categories)
        if (c.id != null) c.id!: c.name,
    };
    final Map<int, String> tagNameById = <int, String>{
      for (final Tag t in tags)
        if (t.id != null) t.id!: t.name,
    };

    final SyncLocalRows local = SyncLocalRows(
      subjectByUuid: <String, Subject>{
        for (final Subject s in subjects)
          if (s.uuid != null) s.uuid!: s,
      },
      categoryByName: <String, ClassCategory>{
        for (final ClassCategory c in categories) c.name: c,
      },
      roomByName: <String, Room>{for (final Room r in rooms) r.name: r},
      tagByName: <String, Tag>{for (final Tag t in tags) t.name: t},
      holidayByKey: <String, Holiday>{
        for (final Holiday h in holidays) '${Dates.keyOf(h.date)}': h,
      },
      slotByUuid: <String, ClassSlot>{
        for (final ClassSlot s in slots)
          if (s.uuid != null) s.uuid!: s,
      },
      extraByUuid: <String, ExtraClass>{
        for (final ExtraClass e in extras)
          if (e.uuid != null) e.uuid!: e,
      },
      overrideByKey: <String, SlotOverride>{
        for (final SlotOverride o in overrides)
          if (slotUuidById[o.slotId] != null)
            SyncItem.overrideKeyFor(slotUuidById[o.slotId]!, o.date): o,
      },
    );

    local.items.addAll(<SyncKind, List<SyncItem>>{
      SyncKind.settings: <SyncItem>[
        SyncItem.settings(settings, changedAt: settings.scheduleChangedAt),
      ],
      SyncKind.category: <SyncItem>[
        for (final ClassCategory c in categories) SyncItem.category(c),
      ],
      SyncKind.room: <SyncItem>[for (final Room r in rooms) SyncItem.room(r)],
      SyncKind.tag: <SyncItem>[for (final Tag t in tags) SyncItem.tag(t)],
      SyncKind.holiday: <SyncItem>[
        for (final Holiday h in holidays) SyncItem.holiday(h),
      ],
      SyncKind.subject: <SyncItem>[
        for (final Subject s in subjects)
          if (s.uuid != null)
            SyncItem.subject(
              s,
              categoryName:
                  s.categoryId == null ? null : categoryNameById[s.categoryId],
            ),
      ],
      SyncKind.slot: <SyncItem>[
        for (final ClassSlot s in slots)
          if (s.uuid != null && uuidById[s.subjectId] != null)
            SyncItem.slot(
              s,
              uuidById[s.subjectId]!,
              categoryName: s.categoryId == null
                  ? null
                  : categoryNameById[s.categoryId],
            ),
      ],
      SyncKind.extraClass: <SyncItem>[
        for (final ExtraClass e in extras)
          if (e.uuid != null && uuidById[e.subjectId] != null)
            SyncItem.extraClass(
              e,
              uuidById[e.subjectId]!,
              categoryName: e.categoryId == null
                  ? null
                  : categoryNameById[e.categoryId],
            ),
      ],
      SyncKind.slotOverride: <SyncItem>[
        for (final SlotOverride o in overrides)
          if (slotUuidById[o.slotId] != null)
            SyncItem.slotOverride(
              o,
              slotUuidById[o.slotId]!,
              subjectUuid: o.subjectId == null ? null : uuidById[o.subjectId],
            ),
      ],
      SyncKind.attendance: <SyncItem>[
        for (final AttendanceRecord r in await repository.getAttendance())
          if (uuidById[r.subjectId] != null)
            SyncItem.attendance(
              r,
              uuidById[r.subjectId]!,
              tagName: r.tagId == null ? null : tagNameById[r.tagId],
              categoryName: r.categoryId == null
                  ? null
                  : categoryNameById[r.categoryId],
            ),
      ],
    });

    return local;
  }
}
