import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/date_utils.dart';
import '../data/db/zeolite_repository.dart';
import '../data/models/attendance_record.dart';
import '../data/models/class_category.dart';
import '../data/models/class_slot.dart';
import '../data/models/extra_class.dart';
import '../data/models/holiday.dart';
import '../data/models/room.dart';
import '../data/models/subject.dart';
import '../data/models/tag.dart';
import '../data/settings/app_settings.dart';
import '../domain/restore_identity.dart';
import 'backup_folder.dart';

/// Result of an import attempt.
class ImportResult {
  const ImportResult({
    required this.success,
    required this.message,
    this.settings,
  });

  final bool success;
  final String message;
  final AppSettings? settings;
}

/// Where an automatic backup is written.
enum BackupDestination {
  /// The folder the user picked, while the grant still holds.
  chosenFolder,

  /// The app's own documents directory — the default, and the fallback.
  appFolder,
}

/// Exports and restores everything as a single JSON document.
///
/// Local-only storage is fast and private, but it means the phone is the only
/// copy — so a one-tap backup you can paste anywhere matters.
class BackupService {
  BackupService(this._repo, this._settingsService, {BackupFolder? folder})
      : _folder = folder ?? BackupFolder();

  final ZeoliteRepository _repo;
  final SettingsService _settingsService;
  final BackupFolder _folder;

  /// v2 added class categories, v3 the saved room list and the day-grid
  /// settings, v4 attendance tags, v5 what a class counts as. Older backups
  /// still import: a missing key just means that feature was unused when the
  /// file was written, which is exactly what an empty list, a zero block
  /// length or a weight of one already mean.
  ///
  /// Bumped for v5 rather than left alone so an older build refuses the file
  /// outright instead of dropping the weights on the way back in.
  static const int formatVersion = 5;

  /// Written into every export so an import can tell our files from anything
  /// else pasted in.
  static const String appTag = 'Zeolite';

  /// The tag written before the app was renamed. Accepted on import and never
  /// on export, so a backup taken under the old name still restores — the file
  /// is the user's data, and a rebrand is no reason to reject it.
  static const String _legacyAppTag = 'Attend It!';

  /// Whether an export's `app` field is one we wrote.
  ///
  /// Separate from the import itself so the rename compatibility can be tested
  /// without a database behind it.
  static bool isRecognisedTag(Object? tag) =>
      tag == appTag || tag == _legacyAppTag;

  /// Builds the full backup document.
  Future<Map<String, Object?>> buildBackup() async {
    final List<ClassCategory> categories = await _repo.getCategories();
    final List<Room> rooms = await _repo.getRooms();
    final List<Tag> tags = await _repo.getTags();
    final List<Subject> subjects = await _repo.getSubjects();
    final List<ClassSlot> slots = await _repo.getSlots();
    final List<ExtraClass> extras = await _repo.getExtraClasses();
    final List<AttendanceRecord> records = await _repo.getAttendance();
    final List<Holiday> holidays = await _repo.getHolidays();
    final AppSettings settings = await _settingsService.load();

    return <String, Object?>{
      'app': appTag,
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': settings.toJson(),
      'categories':
          categories.map((ClassCategory c) => c.toMap()).toList(),
      'rooms': rooms.map((Room r) => r.toMap()).toList(),
      'tags': tags.map((Tag t) => t.toMap()).toList(),
      'subjects': subjects.map((Subject s) => s.toMap()).toList(),
      'slots': slots.map((ClassSlot s) => s.toMap()).toList(),
      'extraClasses': extras.map((ExtraClass e) => e.toMap()).toList(),
      'attendance': records.map((AttendanceRecord r) => r.toMap()).toList(),
      'holidays': holidays.map((Holiday h) => h.toMap()).toList(),
    };
  }

  Future<String> exportToJsonString() async {
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(await buildBackup());
  }

  /// Writes the backup to the app's documents directory and returns the file.
  ///
  /// This location needs no storage permission on modern Android and is
  /// reachable from a file manager under `Android/data/<package>/files`.
  Future<File> exportToFile() async {
    final String json = await exportToJsonString();
    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File(p.join(dir.path, fileNameFor(DateTime.now())));
    return file.writeAsString(json);
  }

  /// `zeolite_backup_20260819_1310.json` — sorts chronologically as plain text,
  /// which is what lets the prune below pick the oldest without parsing dates
  /// or trusting filesystem timestamps.
  static String fileNameFor(DateTime now) {
    final String stamp = '${Dates.keyOf(now)}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    return '$_filePrefix$stamp.json';
  }

  static const String _filePrefix = 'zeolite_backup_';

  /// Five daily files is a working week of history for a few hundred KB, and
  /// old ones are deleted rather than left to grow for the life of the install.
  static const int keepAutoBackups = 5;

  // ------------------------------------------------------------ auto backup

  /// Whether an automatic backup is due. Separate from the writing so it can be
  /// tested without a filesystem, and so the caller skips the export entirely —
  /// serialising the database to find out nothing changed defeats the point.
  static bool isAutoBackupDue({
    required bool enabled,
    required DateTime? lastAt,
    required DateTime now,
  }) {
    if (!enabled) return false;
    if (lastAt == null) return true;
    return Dates.keyOf(now) != Dates.keyOf(lastAt);
  }

  /// Writes one automatic backup and prunes the oldest beyond
  /// [keepAutoBackups]. False when nothing was due.
  ///
  /// Goes to the user's chosen folder when there is one and it is still
  /// writable, and to the app's own documents directory otherwise.
  Future<bool> runAutoBackup({
    required bool enabled,
    required DateTime? lastAt,
    String? folderUri,
    DateTime? nowOverride,
  }) async {
    final DateTime now = nowOverride ?? DateTime.now();
    if (!isAutoBackupDue(enabled: enabled, lastAt: lastAt, now: now)) {
      return false;
    }

    final bool usable = folderUri != null && await _folder.isUsable(folderUri);
    final BackupDestination destination =
        destinationFor(folderUri: folderUri, folderUsable: usable);

    if (destination == BackupDestination.chosenFolder) {
      try {
        await _writeToFolder(folderUri!);
        return true;
      } catch (_) {
        // Whatever went wrong out there, a backup somewhere beats losing the
        // day's backup entirely.
      }
    }

    await exportToFile();
    await pruneAutoBackups();
    return true;
  }

  /// Where a backup goes, given a folder that may or may not still be writable.
  ///
  /// Pure, so the fallback can be tested without a database, a filesystem or a
  /// device — the same reason [isAutoBackupDue] is separate from the writing.
  static BackupDestination destinationFor({
    required String? folderUri,
    required bool folderUsable,
  }) {
    if (folderUri == null || !folderUsable) return BackupDestination.appFolder;
    return BackupDestination.chosenFolder;
  }

  Future<void> _writeToFolder(String folderUri) async {
    final String target = await _folder.resolveFolder(folderUri);
    final String json = await exportToJsonString();
    await _folder.writeJson(target, fileNameFor(DateTime.now()), json);
    try {
      await _pruneFolder(target);
    } catch (_) {
      // Failing to tidy up is not failing to back up, and throwing here would
      // only add a duplicate through the fallback above.
    }
  }

  Future<void> _pruneFolder(String target) async {
    final Map<String, String> ours = <String, String>{
      for (final BackupFile f in await _folder.list(target))
        if (f.name.startsWith(_filePrefix)) f.name: f.uri,
    };
    for (final String name in namesToPrune(ours.keys.toList(), keepAutoBackups)) {
      try {
        await _folder.delete(ours[name]!);
      } catch (_) {
        // A file removed from under us is not worth failing a backup over.
      }
    }
  }

  /// Which backup filenames should go, oldest first, to leave [keep] behind.
  ///
  /// Pure and shared by both destinations, so the filename sort that
  /// [fileNameFor] exists to make possible has one implementation and one test.
  static List<String> namesToPrune(List<String> names, int keep) {
    final List<String> sorted = <String>[...names]..sort();
    final int excess = sorted.length - keep;
    return excess <= 0 ? const <String>[] : sorted.take(excess).toList();
  }

  /// Deletes the oldest exports beyond [keepAutoBackups].
  ///
  /// Exports written into this folder before the file dialog existed are pruned
  /// too — the folder goes when the app does, so nothing here is the durable
  /// copy. A manual export lands wherever the user chose and is never touched.
  Future<void> pruneAutoBackups() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final Map<String, File> backups = <String, File>{
      for (final FileSystemEntity e in dir.listSync())
        if (e is File && p.basename(e.path).startsWith(_filePrefix))
          p.basename(e.path): e,
    };

    for (final String name
        in namesToPrune(backups.keys.toList(), keepAutoBackups)) {
      try {
        backups[name]!.deleteSync();
      } catch (_) {
        // A file the OS has locked or the user deleted underneath us is not
        // worth failing a backup over; the next run tries again.
      }
    }
  }

  /// Replaces all current data with the contents of [jsonString].
  ///
  /// Ids are remapped rather than trusted, so a backup can be restored onto a
  /// database that already has rows without primary-key collisions.
  Future<ImportResult> importFromJsonString(String jsonString) async {
    late final Map<String, Object?> data;
    try {
      final Object? decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, Object?>) {
        return const ImportResult(
          success: false,
          message: 'That does not look like a Zeolite backup.',
        );
      }
      data = decoded;
    } catch (_) {
      return const ImportResult(
        success: false,
        message: 'Could not read that as JSON.',
      );
    }

    if (!isRecognisedTag(data['app'])) {
      return const ImportResult(
        success: false,
        message: 'This file was not created by Zeolite.',
      );
    }

    final int version = (data['formatVersion'] as num?)?.toInt() ?? 0;
    if (version > formatVersion) {
      return const ImportResult(
        success: false,
        message: 'This backup came from a newer version of Zeolite.',
      );
    }

    try {
      // Read before the wipe. A backup written before schema v8 carries no
      // subject uuid and one before v9 no slot uuid, and the identities
      // already on this device are the only place left to recover one from
      // once the tables are empty.
      final List<Subject> existing = await _repo.getSubjects();
      final List<ClassSlot> existingSlots = await _repo.getSlots();
      final List<ExtraClass> existingExtras = await _repo.getExtraClasses();
      final Map<int, String> existingSubjectUuid = <int, String>{
        for (final Subject s in existing)
          if (s.id != null && s.uuid != null) s.id!: s.uuid!,
      };

      await _repo.clearAll();

      // Old id -> newly assigned id, for categories, subjects and tags.
      final Map<int, int> categoryIdMap = <int, int>{};
      final Map<int, int> subjectIdMap = <int, int>{};
      final Map<int, int> tagIdMap = <int, int>{};

      for (final Object? raw in (data['categories'] as List<Object?>?) ??
          const <Object?>[]) {
        if (raw is! Map) continue;
        final Map<String, Object?> map = Map<String, Object?>.from(raw);
        final int? oldId = (map['id'] as num?)?.toInt();
        final ClassCategory category = ClassCategory.fromMap(map);
        final int newId = await _repo.insertCategory(
          ClassCategory(
            name: category.name,
            defaultDurationMinutes: category.defaultDurationMinutes,
            createdAt: category.createdAt,
          ),
        );
        if (oldId != null) categoryIdMap[oldId] = newId;
      }

      // Nothing references a room by id, so these need no id remapping.
      for (final Object? raw in (data['rooms'] as List<Object?>?) ??
          const <Object?>[]) {
        if (raw is! Map) continue;
        final Room room = Room.fromMap(Map<String, Object?>.from(raw));
        await _repo.insertRoom(Room(name: room.name));
      }

      // Tags do need remapping — `attendance.tag_id` points at one. Restored
      // before the marks that reference them, so the ids exist by then.
      for (final Object? raw in (data['tags'] as List<Object?>?) ??
          const <Object?>[]) {
        if (raw is! Map) continue;
        final Map<String, Object?> map = Map<String, Object?>.from(raw);
        final int? oldId = (map['id'] as num?)?.toInt();
        final Tag tag = Tag.fromMap(map);
        final int newId = await _repo.insertTag(Tag(name: tag.name));
        if (oldId != null) tagIdMap[oldId] = newId;
      }

      final List<int?> subjectOldIds = <int?>[];
      final List<Subject> restored = <Subject>[];
      for (final Object? raw in (data['subjects'] as List<Object?>?) ??
          const <Object?>[]) {
        if (raw is! Map) continue;
        final Map<String, Object?> map = Map<String, Object?>.from(raw);
        subjectOldIds.add((map['id'] as num?)?.toInt());
        restored.add(Subject.fromMap(map));
      }

      final Map<int, String> adopted = matchByKey(
        unknown: <RowIdentity>[
          for (final Subject s in restored)
            // A file that already carries uuids needs no matching, and must
            // not be re-pointed at whatever this device filed the code under.
            RowIdentity(key: s.uuid == null ? subjectKey(s.code) : null),
        ],
        known: <RowIdentity>[
          for (final Subject s in existing)
            RowIdentity(key: subjectKey(s.code), uuid: s.uuid),
        ],
      );

      for (int i = 0; i < restored.length; i++) {
        final Subject subject = restored[i];
        final int? oldId = subjectOldIds[i];
        final int newId = await _repo.insertSubject(
          Subject(
            // Carried through, not reissued: a restore onto a second device
            // has to land on the same uuid or the subject syncs as two. An
            // older file has none, so it takes the one held for its code.
            uuid: subject.uuid ?? adopted[i],
            name: subject.name,
            code: subject.code,
            teacher: subject.teacher,
            colorValue: subject.colorValue,
            targetPercent: subject.targetPercent,
            categoryId: subject.categoryId == null
                ? null
                : categoryIdMap[subject.categoryId],
            createdAt: subject.createdAt,
            updatedAt: subject.updatedAt,
            priorHeld: subject.priorHeld,
            priorAttended: subject.priorAttended,
            expectedTotal: subject.expectedTotal,
          ),
        );
        if (oldId != null) subjectIdMap[oldId] = newId;
      }

      // Read back so a slot is keyed on the uuid its subject ended up with,
      // whether that was adopted just now or issued on insert.
      final Map<int, String> subjectUuidById = <int, String>{
        for (final Subject s in await _repo.getSubjects())
          if (s.id != null && s.uuid != null) s.id!: s.uuid!,
      };

      final List<ClassSlot> restoredSlots = <ClassSlot>[];
      for (final Object? raw in (data['slots'] as List<Object?>?) ??
          const <Object?>[]) {
        if (raw is! Map) continue;
        final ClassSlot slot =
            ClassSlot.fromMap(Map<String, Object?>.from(raw));
        if (subjectIdMap[slot.subjectId] == null) continue;
        restoredSlots.add(slot);
      }

      final Map<int, String> adoptedSlots = matchByKey(
        unknown: <RowIdentity>[
          for (final ClassSlot s in restoredSlots)
            RowIdentity(
              key: s.uuid != null
                  ? null
                  : slotKey(subjectUuidById[subjectIdMap[s.subjectId]],
                      s.weekday, s.startMinutes),
            ),
        ],
        known: <RowIdentity>[
          for (final ClassSlot s in existingSlots)
            RowIdentity(
              key: slotKey(
                  existingSubjectUuid[s.subjectId], s.weekday, s.startMinutes),
              uuid: s.uuid,
            ),
        ],
      );

      for (int i = 0; i < restoredSlots.length; i++) {
        final ClassSlot slot = restoredSlots[i];
        // Rebuilt without an id so SQLite assigns a fresh primary key. The
        // uuid is not an id in that sense and has to survive, or the rule
        // comes back as a second class beside the one the account holds.
        await _repo.insertSlot(
          ClassSlot(
            uuid: slot.uuid ?? adoptedSlots[i],
            subjectId: subjectIdMap[slot.subjectId]!,
            weekday: slot.weekday,
            startMinutes: slot.startMinutes,
            endMinutes: slot.endMinutes,
            room: slot.room,
            weight: slot.weight,
            startDate: slot.startDate,
            endDate: slot.endDate,
          ),
        );
      }

      final List<ExtraClass> restoredExtras = <ExtraClass>[];
      for (final Object? raw in (data['extraClasses'] as List<Object?>?) ??
          const <Object?>[]) {
        if (raw is! Map) continue;
        final ExtraClass extra =
            ExtraClass.fromMap(Map<String, Object?>.from(raw));
        if (subjectIdMap[extra.subjectId] == null) continue;
        restoredExtras.add(extra);
      }

      final Map<int, String> adoptedExtras = matchByKey(
        unknown: <RowIdentity>[
          for (final ExtraClass e in restoredExtras)
            RowIdentity(
              key: e.uuid != null
                  ? null
                  : extraKey(subjectUuidById[subjectIdMap[e.subjectId]],
                      Dates.keyOf(e.date), e.startMinutes),
            ),
        ],
        known: <RowIdentity>[
          for (final ExtraClass e in existingExtras)
            RowIdentity(
              key: extraKey(existingSubjectUuid[e.subjectId],
                  Dates.keyOf(e.date), e.startMinutes),
              uuid: e.uuid,
            ),
        ],
      );

      for (int i = 0; i < restoredExtras.length; i++) {
        final ExtraClass extra = restoredExtras[i];
        await _repo.insertExtraClass(
          ExtraClass(
            uuid: extra.uuid ?? adoptedExtras[i],
            subjectId: subjectIdMap[extra.subjectId]!,
            date: extra.date,
            startMinutes: extra.startMinutes,
            endMinutes: extra.endMinutes,
            room: extra.room,
            weight: extra.weight,
            note: extra.note,
          ),
        );
      }

      final List<AttendanceRecord> records = <AttendanceRecord>[];
      for (final Object? raw in (data['attendance'] as List<Object?>?) ??
          const <Object?>[]) {
        if (raw is! Map) continue;
        final Map<String, Object?> map = Map<String, Object?>.from(raw);
        final AttendanceRecord record = AttendanceRecord.fromMap(map);
        final int? subjectId = subjectIdMap[record.subjectId];
        if (subjectId == null) continue;
        records.add(
          AttendanceRecord(
            subjectId: subjectId,
            date: record.date,
            startMinutes: record.startMinutes,
            status: record.status,
            weight: record.weight,
            // An unknown tag id drops to null rather than failing the import.
            // The mark is the data worth keeping; the label is not worth
            // rejecting a whole backup over.
            tagId: record.tagId == null ? null : tagIdMap[record.tagId],
            note: record.note,
            markedAt: record.markedAt,
          ),
        );
      }
      await _repo.setManyAttendance(records);

      for (final Object? raw in (data['holidays'] as List<Object?>?) ??
          const <Object?>[]) {
        if (raw is! Map) continue;
        final Map<String, Object?> map = Map<String, Object?>.from(raw);
        final Holiday holiday = Holiday.fromMap(map);
        await _repo.insertHoliday(
          Holiday(date: holiday.date, name: holiday.name),
        );
      }

      AppSettings? settings;
      final Object? rawSettings = data['settings'];
      if (rawSettings is Map) {
        // The backup folder is this device's, not the file's — it is left out
        // of the export on purpose, so restoring must carry the current one
        // forward rather than read its absence as "no folder chosen".
        final AppSettings current = await _settingsService.load();
        settings = AppSettings.fromJson(Map<String, Object?>.from(rawSettings))
            .copyWith(
          backupFolderUri: current.backupFolderUri,
          backupFolderName: current.backupFolderName,
        );
        await _settingsService.save(settings);
      }

      return ImportResult(
        success: true,
        message: 'Backup restored.',
        settings: settings,
      );
    } catch (error) {
      return ImportResult(
        success: false,
        message: 'Import failed: $error',
      );
    }
  }
}
