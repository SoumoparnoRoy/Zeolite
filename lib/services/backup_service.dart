import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/date_utils.dart';
import '../core/report_error.dart';
import '../data/db/zeolite_repository.dart';
import '../data/models/attendance_record.dart';
import '../data/models/class_category.dart';
import '../data/models/class_slot.dart';
import '../data/models/extra_class.dart';
import '../data/models/holiday.dart';
import '../data/models/room.dart';
import '../data/models/slot_override.dart';
import '../data/models/subject.dart';
import '../data/models/tag.dart';
import '../data/settings/app_settings.dart';
import '../domain/restore_identity.dart';
import 'backup_folder.dart';

/// How a restore ended. The words are the screen's to choose.
enum ImportOutcome {
  restored,
  notABackup,
  notJson,
  notZeolite,
  tooNew,

  /// The file could not be read off the device at all.
  unreadable,

  /// Recognised, but writing it failed and nothing was changed.
  failed,
}

/// Result of an import attempt.
class ImportResult {
  const ImportResult(this.outcome, {this.settings});

  final ImportOutcome outcome;
  final AppSettings? settings;

  bool get success => outcome == ImportOutcome.restored;
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
    final List<SlotOverride> overrides = await _repo.getSlotOverrides();
    final List<ExtraClass> extras = await _repo.getExtraClasses();
    final List<AttendanceRecord> records = await _repo.getAttendance();
    final List<Holiday> holidays = await _repo.getHolidays();
    final AppSettings settings = await _settingsService.load();

    return <String, Object?>{
      'app': appTag,
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': settings.toJson(),
      'categories': categories.map((ClassCategory c) => c.toMap()).toList(),
      'rooms': rooms.map((Room r) => r.toMap()).toList(),
      'tags': tags.map((Tag t) => t.toMap()).toList(),
      'subjects': subjects.map((Subject s) => s.toMap()).toList(),
      'slots': slots.map((ClassSlot s) => s.toMap()).toList(),
      'slotOverrides': overrides.map((SlotOverride o) => o.toMap()).toList(),
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

  // Automatic backups

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
    for (final String name
        in namesToPrune(ours.keys.toList(), keepAutoBackups)) {
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
        return const ImportResult(ImportOutcome.notABackup);
      }
      data = decoded;
    } catch (_) {
      return const ImportResult(ImportOutcome.notJson);
    }

    if (!isRecognisedTag(data['app'])) {
      return const ImportResult(ImportOutcome.notZeolite);
    }

    final int version = (data['formatVersion'] as num?)?.toInt() ?? 0;
    if (version > formatVersion) {
      return const ImportResult(ImportOutcome.tooNew);
    }

    AppSettings? originalSettings;
    bool settingsWriteAttempted = false;
    try {
      // Read before the wipe. A backup written before schema v8 carries no
      // subject uuid and one before v9 no slot uuid, and the identities
      // already on this device are the only place left to recover one from
      // once the tables are empty.
      final _Existing existing = _Existing(
        subjects: await _repo.getSubjects(),
        slots: await _repo.getSlots(),
        extras: await _repo.getExtraClasses(),
      );

      originalSettings = await _settingsService.load();
      final AppSettings? settings = await _repo.transaction(
        (ZeoliteRepository repository) async {
          await repository.clearAll();
          final _IdMaps ids = _IdMaps();
          // In this order: each table points at rows of the ones before it.
          await _restoreCategories(repository, data, ids);
          await _restoreRooms(repository, data);
          await _restoreTags(repository, data, ids);
          await _restoreSubjects(repository, data, ids, existing);
          // Read back so a slot is keyed on the uuid its subject ended up
          // with, whether that was adopted just now or issued on insert.
          final Map<int, String> subjectUuids = <int, String>{
            for (final Subject s in await repository.getSubjects())
              if (s.id != null && s.uuid != null) s.id!: s.uuid!,
          };
          await _restoreSlots(repository, data, ids, existing, subjectUuids);
          await _restoreOverrides(repository, data, ids);
          await _restoreExtras(repository, data, ids, existing, subjectUuids);
          await _restoreAttendance(repository, data, ids);
          await _restoreHolidays(repository, data);

          final Object? rawSettings = data['settings'];
          if (rawSettings is Map) {
            final AppSettings importedSettings = AppSettings.fromJson(
              Map<String, Object?>.from(rawSettings),
            ).onDeviceOf(originalSettings!);
            settingsWriteAttempted = true;
            await _settingsService.save(importedSettings);
            return importedSettings;
          }
          return null;
        },
      );

      return ImportResult(ImportOutcome.restored, settings: settings);
    } catch (error, stack) {
      reportError(error, stack, where: 'backup restore');
      if (settingsWriteAttempted && originalSettings != null) {
        try {
          await _settingsService.save(originalSettings);
        } catch (_) {
          // The database transaction has already rolled back.
        }
      }
      return const ImportResult(ImportOutcome.failed);
    }
  }

  // Each row is read whole and only its ids are rewritten, so a column added
  // later comes back without the restore having to name it. Rebuilding rows
  // field by field silently dropped every column it was not told about.

  /// The rows of one table, each with its own id taken out — SQLite assigns
  /// a new one — and the old id beside it for the tables that point here.
  static Iterable<({int? oldId, Map<String, Object?> row})> _rows(
    Map<String, Object?> data,
    String table,
  ) sync* {
    for (final Object? raw
        in (data[table] as List<Object?>?) ?? const <Object?>[]) {
      if (raw is! Map) continue;
      final Map<String, Object?> row = Map<String, Object?>.from(raw);
      yield (oldId: (row.remove('id') as num?)?.toInt(), row: row);
    }
  }

  static Future<void> _restoreCategories(
    ZeoliteRepository repository,
    Map<String, Object?> data,
    _IdMaps ids,
  ) async {
    for (final (:int? oldId, :Map<String, Object?> row)
        in _rows(data, 'categories')) {
      final int newId =
          await repository.insertCategory(ClassCategory.fromMap(row));
      if (oldId != null) ids.categories[oldId] = newId;
    }
  }

  /// Nothing references a room by id, so these need no remapping.
  static Future<void> _restoreRooms(
    ZeoliteRepository repository,
    Map<String, Object?> data,
  ) async {
    for (final (oldId: _, :Map<String, Object?> row) in _rows(data, 'rooms')) {
      await repository.insertRoom(Room.fromMap(row));
    }
  }

  /// Before the marks, because `attendance.tag_id` points at one.
  static Future<void> _restoreTags(
    ZeoliteRepository repository,
    Map<String, Object?> data,
    _IdMaps ids,
  ) async {
    for (final (:int? oldId, :Map<String, Object?> row)
        in _rows(data, 'tags')) {
      final int newId = await repository.insertTag(Tag.fromMap(row));
      if (oldId != null) ids.tags[oldId] = newId;
    }
  }

  static Future<void> _restoreSubjects(
    ZeoliteRepository repository,
    Map<String, Object?> data,
    _IdMaps ids,
    _Existing existing,
  ) async {
    final List<({int? oldId, Subject subject})> restored =
        <({int? oldId, Subject subject})>[
      for (final (:int? oldId, :Map<String, Object?> row)
          in _rows(data, 'subjects'))
        (oldId: oldId, subject: Subject.fromMap(row)),
    ];
    final Map<int, String> adopted = matchByKey(
      unknown: <RowIdentity>[
        for (final (oldId: _, :Subject subject) in restored)
          // A file that already carries uuids needs no matching, and must not
          // be re-pointed at whatever this device filed the code under.
          RowIdentity(
            key: subject.uuid == null ? subjectKey(subject.code) : null,
          ),
      ],
      known: <RowIdentity>[
        for (final Subject s in existing.subjects)
          RowIdentity(key: subjectKey(s.code), uuid: s.uuid),
      ],
    );

    for (int i = 0; i < restored.length; i++) {
      final (:int? oldId, :Subject subject) = restored[i];
      final int? categoryId = ids.category(subject.categoryId);
      final int newId = await repository.insertSubject(
        subject.copyWith(
          // Carried through, not reissued: a restore onto a second device has
          // to land on the same uuid or the subject syncs as two. An older
          // file has none, so it takes the one held for its code.
          uuid: subject.uuid ?? adopted[i],
          categoryId: categoryId,
          clearCategory: categoryId == null,
        ),
      );
      if (oldId != null) ids.subjects[oldId] = newId;
    }
  }

  static Future<void> _restoreSlots(
    ZeoliteRepository repository,
    Map<String, Object?> data,
    _IdMaps ids,
    _Existing existing,
    Map<int, String> subjectUuids,
  ) async {
    final List<({int? oldId, ClassSlot slot})> restored =
        <({int? oldId, ClassSlot slot})>[
      for (final (:int? oldId, :Map<String, Object?> row)
          in _rows(data, 'slots'))
        if (ClassSlot.fromMap(row) case final ClassSlot slot
            when ids.subjects[slot.subjectId] != null)
          (oldId: oldId, slot: slot),
    ];
    final Map<int, String> adopted = matchByKey(
      unknown: <RowIdentity>[
        for (final (oldId: _, :ClassSlot slot) in restored)
          RowIdentity(
            key: slot.uuid != null
                ? null
                : slotKey(subjectUuids[ids.subjects[slot.subjectId]],
                    slot.weekday, slot.startMinutes),
          ),
      ],
      known: <RowIdentity>[
        for (final ClassSlot s in existing.slots)
          RowIdentity(
            key: slotKey(
                existing.subjectUuid[s.subjectId], s.weekday, s.startMinutes),
            uuid: s.uuid,
          ),
      ],
    );

    for (int i = 0; i < restored.length; i++) {
      final (:int? oldId, :ClassSlot slot) = restored[i];
      final int? categoryId = ids.category(slot.categoryId);
      // The uuid is not an id in the SQLite sense and has to survive, or the
      // rule comes back as a second class beside the one the account holds.
      final int newId = await repository.insertSlot(
        slot.copyWith(
          uuid: slot.uuid ?? adopted[i],
          subjectId: ids.subjects[slot.subjectId],
          categoryId: categoryId,
          clearCategory: categoryId == null,
        ),
      );
      if (oldId != null) ids.slots[oldId] = newId;
    }
  }

  static Future<void> _restoreOverrides(
    ZeoliteRepository repository,
    Map<String, Object?> data,
    _IdMaps ids,
  ) async {
    await repository.insertSlotOverrides(<SlotOverride>[
      for (final (oldId: _, :Map<String, Object?> row)
          in _rows(data, 'slotOverrides'))
        if (SlotOverride.fromMap(row) case final SlotOverride override
            // A rule the restore dropped takes its exceptions with it: an
            // override with no slot is a foreign key pointing nowhere.
            when ids.slots[override.slotId] != null)
          override.copyWith(
            slotId: ids.slots[override.slotId],
            subjectId: override.subjectId == null
                ? null
                : ids.subjects[override.subjectId!],
          ),
    ]);
  }

  static Future<void> _restoreExtras(
    ZeoliteRepository repository,
    Map<String, Object?> data,
    _IdMaps ids,
    _Existing existing,
    Map<int, String> subjectUuids,
  ) async {
    final List<ExtraClass> restored = <ExtraClass>[
      for (final (oldId: _, :Map<String, Object?> row)
          in _rows(data, 'extraClasses'))
        if (ExtraClass.fromMap(row) case final ExtraClass extra
            when ids.subjects[extra.subjectId] != null)
          extra,
    ];
    final Map<int, String> adopted = matchByKey(
      unknown: <RowIdentity>[
        for (final ExtraClass e in restored)
          RowIdentity(
            key: e.uuid != null
                ? null
                : extraKey(subjectUuids[ids.subjects[e.subjectId]],
                    Dates.keyOf(e.date), e.startMinutes),
          ),
      ],
      known: <RowIdentity>[
        for (final ExtraClass e in existing.extras)
          RowIdentity(
            key: extraKey(existing.subjectUuid[e.subjectId],
                Dates.keyOf(e.date), e.startMinutes),
            uuid: e.uuid,
          ),
      ],
    );

    for (int i = 0; i < restored.length; i++) {
      final ExtraClass extra = restored[i];
      final int? categoryId = ids.category(extra.categoryId);
      await repository.insertExtraClass(
        extra.copyWith(
          uuid: extra.uuid ?? adopted[i],
          subjectId: ids.subjects[extra.subjectId],
          categoryId: categoryId,
          clearCategory: categoryId == null,
        ),
      );
    }
  }

  static Future<void> _restoreAttendance(
    ZeoliteRepository repository,
    Map<String, Object?> data,
    _IdMaps ids,
  ) async {
    await repository.setManyAttendance(<AttendanceRecord>[
      for (final (oldId: _, :Map<String, Object?> row)
          in _rows(data, 'attendance'))
        if (AttendanceRecord.fromMap(row) case final AttendanceRecord record
            when ids.subjects[record.subjectId] != null)
          record.copyWith(
            subjectId: ids.subjects[record.subjectId],
            categoryId: ids.category(record.categoryId),
            clearCategory: ids.category(record.categoryId) == null,
            // An unknown tag drops to null rather than failing the import.
            // The mark is the data worth keeping; the label is not worth
            // rejecting a whole backup over.
            tagId: ids.tag(record.tagId),
            clearTag: ids.tag(record.tagId) == null,
          ),
    ]);
  }

  static Future<void> _restoreHolidays(
    ZeoliteRepository repository,
    Map<String, Object?> data,
  ) async {
    for (final (oldId: _, :Map<String, Object?> row)
        in _rows(data, 'holidays')) {
      await repository.insertHoliday(Holiday.fromMap(row));
    }
  }
}

/// Old id → new id, per table, filled as each one goes back in.
class _IdMaps {
  final Map<int, int> categories = <int, int>{};
  final Map<int, int> subjects = <int, int>{};
  final Map<int, int> tags = <int, int>{};
  final Map<int, int> slots = <int, int>{};

  /// A type the file does not hold falls back to inheriting, as if unset.
  int? category(int? oldId) => oldId == null ? null : categories[oldId];

  int? tag(int? oldId) => oldId == null ? null : tags[oldId];
}

/// What the device held before the wipe, kept for the identities a file
/// written before uuids existed has to borrow.
class _Existing {
  _Existing({
    required this.subjects,
    required this.slots,
    required this.extras,
  }) : subjectUuid = <int, String>{
          for (final Subject s in subjects)
            if (s.id != null && s.uuid != null) s.id!: s.uuid!,
        };

  final List<Subject> subjects;
  final List<ClassSlot> slots;
  final List<ExtraClass> extras;
  final Map<int, String> subjectUuid;
}
