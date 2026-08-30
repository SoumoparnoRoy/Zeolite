import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../core/date_utils.dart';
import '../data/db/zeolite_repository.dart';
import '../data/models/attendance_record.dart';
import '../data/models/attendance_status.dart';
import '../data/models/class_category.dart';
import '../data/models/class_session.dart';
import '../data/models/class_slot.dart';
import '../data/models/extra_class.dart';
import '../data/models/holiday.dart';
import '../data/models/room.dart';
import '../data/models/subject.dart';
import '../data/models/tag.dart';
import '../data/settings/app_settings.dart';
import '../domain/attendance_log.dart';
import '../domain/attendance_stats.dart';
import '../domain/attendance_totals_import.dart';
import '../domain/notion_import.dart';
import '../domain/attendance_totals_ocr.dart';
import '../domain/day_grid.dart';
import '../domain/schedule_engine.dart';
import '../domain/sync/sync_merge.dart';
import '../domain/sync/sync_target.dart';
import '../domain/tag_stats.dart';
import '../domain/timetable_import.dart';
import '../services/backup_folder.dart';
import '../services/backup_service.dart';
import '../services/notification_service.dart';
import '../services/sync/sync_coordinator.dart';
import 'notion_sync_providers.dart';
import 'sync_providers.dart';
import 'undo.dart';

// ---------------------------------------------------------------- singletons

final repositoryProvider = Provider<ZeoliteRepository>(
  (ref) => ZeoliteRepository(),
);

final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(),
);

/// Whether the chosen backup folder can still be written to. Asked when
/// Settings draws rather than remembered, since the grant can go while the app
/// is not looking.
final backupFolderUsableProvider = FutureProvider<bool>((ref) async {
  final String? uri = ref.watch(settingsProvider).value?.backupFolderUri;
  if (uri == null) return false;
  return BackupFolder().isUsable(uri);
});

/// Whether class reminders can fire to the minute. Asked when Settings draws,
/// since the permission is granted on a system screen the app cannot watch.
final exactAlarmsProvider = FutureProvider<bool>(
  (ref) => NotificationService.instance.canScheduleExactly(),
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    ref.watch(repositoryProvider),
    ref.watch(settingsServiceProvider),
  ),
);

// ----------------------------------------------------------------- settings

/// Loads and mutates [AppSettings]. Every write persists immediately so the
/// app can be killed at any moment without losing a preference.
class SettingsController extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    return ref.watch(settingsServiceProvider).load();
  }

  /// Every settings write goes through here, which is why the sync stamp is
  /// applied here too — and only when something that shapes the timetable
  /// actually moved. Stamping on every save would make a theme change look
  /// like a newer schedule to the other device.
  Future<void> save(AppSettings settings) async {
    final bool scheduleMoved = SyncItem.settings(settings).hash !=
        SyncItem.settings(state.value ?? const AppSettings()).hash;
    final AppSettings next = scheduleMoved
        ? settings.copyWith(scheduleChangedAt: DateTime.now())
        : settings;

    state = AsyncValue<AppSettings>.data(next);
    await ref.read(settingsServiceProvider).save(next);
    // Settings do not go through `_refresh`, so the one row with no table
    // would otherwise wait for a resume to travel.
    if (scheduleMoved) {
      ref.read(syncSchedulerProvider)?.onLocalChange();
      ref.read(notionSchedulerProvider)?.onLocalChange();
    }
  }

  Future<void> setSemester(DateTime start, DateTime end) async {
    final AppSettings? current = state.value;
    if (current == null) return;
    await save(
      current.copyWith(
        semesterStart: Dates.dayOf(start),
        semesterEnd: Dates.dayOf(end),
        onboarded: true,
      ),
    );
  }

  /// Whether marks outside the semester count towards the figures — a view of
  /// the same marks, reversible at any time.
  Future<void> setCountOutsideTerm(bool value) async {
    final AppSettings? current = state.value;
    if (current == null) return;
    await save(current.copyWith(countOutsideTerm: value));
  }

  Future<void> setBackupFolder(String uri, String name) async {
    final AppSettings? current = state.value;
    if (current == null) return;
    await save(current.copyWith(backupFolderUri: uri, backupFolderName: name));
  }

  Future<void> clearBackupFolder() async {
    final AppSettings? current = state.value;
    if (current == null) return;
    await save(current.copyWith(clearBackupFolder: true));
  }

  Future<void> setTarget(double percent) async {
    final AppSettings? current = state.value;
    if (current == null) return;
    await save(current.copyWith(targetPercent: percent.clamp(0, 100)));
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

// --------------------------------------------------------------- timetable

/// Everything the schedule engine needs, loaded in one round trip.
class TimetableData {
  const TimetableData({
    required this.categories,
    required this.subjects,
    required this.slots,
    required this.extras,
    required this.holidays,
    required this.records,
    this.rooms = const <Room>[],
    this.tags = const <Tag>[],
  });

  final List<ClassCategory> categories;
  final List<Subject> subjects;

  /// Saved room numbers, offered wherever a room is typed. Defaulted because
  /// this is a suggestion list rather than timetable structure — nothing breaks
  /// when it is empty, which is also how every pre-v3 install starts.
  final List<Room> rooms;

  /// The user's attendance labels. Defaulted for the same reason as [rooms]:
  /// it is optional vocabulary, and every pre-v4 install starts with none.
  final List<Tag> tags;

  final List<ClassSlot> slots;
  final List<ExtraClass> extras;
  final List<Holiday> holidays;
  final List<AttendanceRecord> records;

  bool get isEmpty => subjects.isEmpty;

  ClassCategory? categoryFor(Subject? subject) {
    final int? id = subject?.categoryId;
    if (id == null) return null;
    for (final ClassCategory category in categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  ClassCategory? categoryById(int? id) {
    if (id == null) return null;
    for (final ClassCategory category in categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  Tag? tagById(int? id) {
    if (id == null) return null;
    for (final Tag tag in tags) {
      if (tag.id == id) return tag;
    }
    return null;
  }

  Subject? subjectById(int? id) {
    if (id == null) return null;
    for (final Subject subject in subjects) {
      if (subject.id == id) return subject;
    }
    return null;
  }
}

/// Reads the whole timetable. Datasets here are small — a semester is a few
/// hundred rows at most — so loading it once and deriving everything in memory
/// is both simpler and faster than querying per screen.
final timetableProvider = FutureProvider<TimetableData>((ref) async {
  final ZeoliteRepository repo = ref.watch(repositoryProvider);
  final List<ClassCategory> categories = await repo.getCategories();
  final List<Subject> subjects = await repo.getSubjects();
  final List<ClassSlot> slots = await repo.getSlots();
  final List<ExtraClass> extras = await repo.getExtraClasses();
  final List<Holiday> holidays = await repo.getHolidays();
  final List<AttendanceRecord> records = await repo.getAttendance();
  final List<Room> rooms = await repo.getRooms();
  final List<Tag> tags = await repo.getTags();
  return TimetableData(
    categories: categories,
    subjects: subjects,
    slots: slots,
    extras: extras,
    holidays: holidays,
    records: records,
    rooms: rooms,
    tags: tags,
  );
});

/// The expansion engine, rebuilt whenever data or semester bounds change.
final scheduleEngineProvider = Provider<ScheduleEngine?>((ref) {
  final TimetableData? data = ref.watch(timetableProvider).value;
  final AppSettings? settings = ref.watch(settingsProvider).value;
  if (data == null) return null;
  return ScheduleEngine(
    subjects: data.subjects,
    slots: data.slots,
    extras: data.extras,
    holidays: data.holidays,
    records: data.records,
    semesterStart: settings?.semesterStart,
    semesterEnd: settings?.semesterEnd,
  );
});

/// The day currently shown on the Today screen.
final selectedDateProvider =
    NotifierProvider<SelectedDateController, DateTime>(
  SelectedDateController.new,
);

class SelectedDateController extends Notifier<DateTime> {
  @override
  DateTime build() => Dates.today();

  void select(DateTime date) => state = Dates.dayOf(date);

  void goToToday() => state = Dates.today();

  void shiftDays(int days) => state = Dates.addDays(state, days);
}

/// Classes on the currently selected day.
final selectedDaySessionsProvider = Provider<List<ClassSession>>((ref) {
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
  final DateTime date = ref.watch(selectedDateProvider);
  if (engine == null) return const <ClassSession>[];
  return engine.sessionsOn(date);
});

/// Past classes you have not marked yet.
final unmarkedSessionsProvider = Provider<List<ClassSession>>((ref) {
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
  if (engine == null) return const <ClassSession>[];
  return engine.unmarkedSessions();
});

final nextSessionProvider = Provider<ClassSession?>((ref) {
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
  return engine?.nextSession();
});

/// The week shown on the timetable screen, keyed by its Monday.
final visibleWeekProvider =
    NotifierProvider<VisibleWeekController, DateTime>(
  VisibleWeekController.new,
);

class VisibleWeekController extends Notifier<DateTime> {
  @override
  DateTime build() => Dates.startOfWeek(Dates.today());

  void shiftWeeks(int weeks) => state = Dates.addDays(state, weeks * 7);

  void goToThisWeek() => state = Dates.startOfWeek(Dates.today());
}

/// Which of the two home layouts is showing: the day's classes, or the week as
/// a block grid.
enum HomeView { day, grid }

final homeViewProvider = NotifierProvider<HomeViewController, HomeView>(
  HomeViewController.new,
);

class HomeViewController extends Notifier<HomeView> {
  @override
  HomeView build() => HomeView.day;

  void toggle() =>
      state = state == HomeView.day ? HomeView.grid : HomeView.day;
}

// ------------------------------------------------------------------- stats

/// Attendance figures for every subject, plus the aggregate.
final statsProvider = Provider<OverallStats>((ref) {
  final TimetableData? data = ref.watch(timetableProvider).value;
  final AppSettings? settings = ref.watch(settingsProvider).value;
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);

  final double globalTarget = (settings?.targetRatio ?? 0.75);
  if (data == null) {
    return OverallStats(subjects: const <SubjectStats>[], target: globalTarget);
  }

  // Count marks straight from the records — cheaper and more accurate than
  // re-expanding the whole semester, since a mark survives rule edits. Only
  // this term's unless the user has said otherwise: the header above these
  // figures says so, and an install keeps marks from before the dates were
  // last moved.
  final AppSettings term = settings ?? const AppSettings();
  final Map<int, Map<AttendanceStatus, int>> counts =
      <int, Map<AttendanceStatus, int>>{};
  // Subjects where something counts as more than one class, which is all the
  // headlines need in order to say "periods" instead.
  final Set<int> weighted = <int>{};
  for (final AttendanceRecord record in data.records) {
    if (!term.countsTowardsPercentage(record.date)) continue;
    if (record.weight != 1) weighted.add(record.subjectId);
    counts.putIfAbsent(record.subjectId, () => <AttendanceStatus, int>{});
    counts[record.subjectId]![record.status] =
        (counts[record.subjectId]![record.status] ?? 0) + record.weight;
  }
  // A subject can be weighted before anything is marked against it, and the
  // projection it is about to be judged on is already in periods.
  for (final ClassSlot slot in data.slots) {
    if (slot.weight != 1) weighted.add(slot.subjectId);
  }
  for (final ExtraClass extra in data.extras) {
    if (extra.weight != 1) weighted.add(extra.subjectId);
  }

  final Map<int, int> remaining =
      engine?.remainingSessionsBySubject() ?? <int, int>{};

  final List<SubjectStats> subjectStats = <SubjectStats>[];
  for (final Subject subject in data.subjects) {
    final int? id = subject.id;
    if (id == null) continue;
    final Map<AttendanceStatus, int> byStatus =
        counts[id] ?? const <AttendanceStatus, int>{};
    subjectStats.add(
      SubjectStats(
        subject: subject,
        present: byStatus[AttendanceStatus.present] ?? 0,
        absent: byStatus[AttendanceStatus.absent] ?? 0,
        cancelled: byStatus[AttendanceStatus.cancelled] ?? 0,
        target: subject.targetPercent == null
            ? globalTarget
            : subject.targetPercent! / 100.0,
        plannedFromSlots: remaining[id] ?? 0,
        weighted: weighted.contains(id),
      ),
    );
  }

  subjectStats.sort((SubjectStats a, SubjectStats b) {
    // Struggling subjects float to the top; unmarked ones sink.
    if (a.hasData != b.hasData) return a.hasData ? -1 : 1;
    return a.ratio.compareTo(b.ratio);
  });

  return OverallStats(subjects: subjectStats, target: globalTarget);
});

/// Stats for one subject, looked up from [statsProvider] by id.
final subjectStatsProvider =
    Provider.family<SubjectStats?, int>((ref, int subjectId) {
  final OverallStats stats = ref.watch(statsProvider);
  for (final SubjectStats s in stats.subjects) {
    if (s.subject.id == subjectId) return s;
  }
  return null;
});

// ------------------------------------------------------------------- tags

/// Every tag with the marks carrying it.
///
/// Derived from the records already in memory rather than queried, so it
/// refreshes with the same `timetableProvider` invalidation as everything else
/// and cannot fall out of step with the stats beside it.
final tagBreakdownsProvider = Provider<List<TagBreakdown>>((ref) {
  final TimetableData? data = ref.watch(timetableProvider).value;
  if (data == null) return const <TagBreakdown>[];
  // The same window as the figures above it, or the two halves of Stats
  // would report different terms.
  final AppSettings term =
      ref.watch(settingsProvider).value ?? const AppSettings();
  return buildTagBreakdowns(
    tags: data.tags,
    records: data.records
        .where((AttendanceRecord r) => term.countsTowardsPercentage(r.date))
        .toList(),
    subjects: data.subjects,
  );
});

/// Marks dated outside the semester, so the stats screen can say so instead of
/// quietly leaving them out of every figure on it.
final outOfTermMarksProvider = Provider<OutOfTermMarks>((ref) {
  final TimetableData? data = ref.watch(timetableProvider).value;
  if (data == null) return const OutOfTermMarks(count: 0);
  final AppSettings term =
      ref.watch(settingsProvider).value ?? const AppSettings();
  return OutOfTermMarks.from(data.records, term);
});

/// Whether anything is tagged at all. The stats screen hides its tag section
/// on this, so an install that never opens Settings never sees the feature.
final hasTaggedMarksProvider = Provider<bool>((ref) {
  final List<TagBreakdown> breakdowns = ref.watch(tagBreakdownsProvider);
  return breakdowns.any((TagBreakdown b) => !b.isEmpty);
});

// ---------------------------------------------------------- attendance log

/// Furthest back the log will look.
///
/// [ScheduleEngine.sessionsBetween] caps expansion at 400 days *from its start
/// date*, so an unclamped range would silently drop the newest days rather than
/// the oldest — the opposite of what anyone wants here.
const int _maxLogDays = 400;

/// One subject's full attendance history, newest first.
///
/// Expanding the term day by day costs the same as the stats already pay, and a
/// term is a few hundred days, so this stays cheap. `family` caches per subject
/// and recomputes only when the timetable or semester bounds change.
final attendanceLogProvider =
    Provider.family<List<AttendanceLogEntry>, int>((ref, int subjectId) {
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
  final TimetableData? data = ref.watch(timetableProvider).value;
  if (engine == null || data == null) return const <AttendanceLogEntry>[];

  final DateTime today = Dates.today();
  final DateTime earliest = Dates.addDays(today, -_maxLogDays);

  // Start at the semester opening, but stretch back far enough to include any
  // mark that predates it. Those no longer count towards the term, which is
  // exactly why they have to stay reachable: this is where you see one and
  // remove it.
  DateTime from = engine.semesterStart ?? today;
  for (final AttendanceRecord record in data.records) {
    if (record.subjectId != subjectId) continue;
    if (record.date.isBefore(from)) from = Dates.dayOf(record.date);
  }
  if (from.isBefore(earliest)) from = earliest;
  if (from.isAfter(today)) from = today;

  final List<ClassSession> past = engine
      .sessionsBetween(from, today)
      .where((ClassSession s) => s.subject.id == subjectId)
      .toList();

  return buildAttendanceLog(
    subjectId: subjectId,
    pastSessions: past,
    records: data.records,
  );
});

// ------------------------------------------------------------ in-app alerts

/// Subjects the app has to warn about itself, because their system
/// notification is switched off and in-app alerts are on. Empty whenever the
/// tray is already handling it, so the two can never both fire.
final inAppAlertsProvider = Provider<List<SubjectStats>>((ref) {
  final AppSettings? settings = ref.watch(settingsProvider).value;
  if (settings == null || !settings.showDangerInApp) {
    return const <SubjectStats>[];
  }
  return NotificationService.subjectsInDanger(ref.watch(statsProvider));
});

/// Subjects already shown in a popup, so opening the app or marking another
/// class does not re-raise a warning you have just dismissed. A subject that
/// recovers and slips again is announced afresh.
class AnnouncedAlertsController extends Notifier<Set<int>> {
  @override
  Set<int> build() => <int>{};

  /// The subjects in [alerts] that have not been announced yet.
  List<SubjectStats> pending(List<SubjectStats> alerts) {
    return alerts
        .where((SubjectStats s) => !state.contains(s.subject.id))
        .toList();
  }

  void markAnnounced(Iterable<SubjectStats> alerts) {
    final Set<int> ids = <int>{
      for (final SubjectStats s in alerts)
        if (s.subject.id != null) s.subject.id!,
    };
    if (ids.isEmpty) return;
    state = <int>{...state, ...ids};
  }

  /// Drops subjects that are no longer in danger so they can warn again later.
  void retainOnly(Iterable<SubjectStats> alerts) {
    final Set<int> live = <int>{
      for (final SubjectStats s in alerts)
        if (s.subject.id != null) s.subject.id!,
    };
    final Set<int> kept = state.intersection(live);
    if (kept.length != state.length) state = kept;
  }
}

final announcedAlertsProvider =
    NotifierProvider<AnnouncedAlertsController, Set<int>>(
  AnnouncedAlertsController.new,
);

/// The day divided into uniform lecture blocks, or [DayGrid.none] until the
/// user has set a block length.
final dayGridProvider = Provider<DayGrid>((ref) {
  return ref.watch(settingsProvider).value?.dayGrid ?? DayGrid.none;
});

/// Resolves the default length of a class for a given subject:
/// the subject's category first, then the global setting.
///
/// This is what lets picking a start time fill in the end time — a Lab gets
/// two hours where a Theory class gets one, without asking every time.
final defaultDurationProvider =
    Provider.family<int, int?>((ref, int? subjectId) {
  final int fallback =
      ref.watch(settingsProvider).value?.defaultClassDurationMinutes ?? 60;
  final TimetableData? data = ref.watch(timetableProvider).value;
  if (data == null || subjectId == null) return fallback;
  final ClassCategory? category =
      data.categoryFor(data.subjectById(subjectId));
  return category?.defaultDurationMinutes ?? fallback;
});

/// Says *why* a class came out the length it did — "Lab · 2 blocks · 1h 40m",
/// or "no category · 1h" when the global fallback was used.
///
/// Without this the two rules are indistinguishable on screen, which is how a
/// subject that was never given a category reads as a broken feature rather
/// than as a subject that was never given a category.
final defaultDurationLabelProvider =
    Provider.family<String, int?>((ref, int? subjectId) {
  final int minutes = ref.watch(defaultDurationProvider(subjectId));
  final DayGrid grid = ref.watch(dayGridProvider);
  final TimetableData? data = ref.watch(timetableProvider).value;
  final ClassCategory? category =
      data?.categoryFor(data.subjectById(subjectId));

  final List<String> parts = <String>[category?.name ?? 'no category'];
  if (grid.isWholeBlocks(minutes)) {
    final int blocks = grid.blocksFor(minutes);
    parts.add('$blocks ${blocks == 1 ? 'block' : 'blocks'}');
  }
  parts.add(Clock.formatDuration(minutes));
  return parts.join(' · ');
});

// ------------------------------------------------------------------ actions

/// Every mutation the UI can perform. Each one writes to the database and then
/// invalidates [timetableProvider], which cascades a rebuild through the
/// engine, the day lists and the stats in a single pass.
class TimetableActions {
  TimetableActions(this._ref);

  final Ref _ref;

  ZeoliteRepository get _repo => _ref.read(repositoryProvider);

  final UndoStore _undo = UndoStore();

  Future<void> _refresh() async {
    await _reload();
    // Every scheduler, or a change would reach one target and quietly never
    // reach the other.
    _ref.read(syncSchedulerProvider)?.onLocalChange();
    _ref.read(notionSchedulerProvider)?.onLocalChange();
  }

  /// Split out of [_refresh] because a pull needs all of this without
  /// announcing a local change, which would schedule the rows it just brought
  /// down straight back up.
  Future<void> _reload() async {
    // Every mutation ends here, so this is the one place the pending undo has
    // to be dropped: restoring it would throw away whatever happened since.
    _undo.drop();
    _mergeUndoToken = null;
    _ref.invalidate(timetableProvider);
    await _ref.read(timetableProvider.future);
    await _syncNotifications();
  }

  /// A run writes straight through the repository and the settings service, so
  /// without this nothing reading either provider knows the database moved.
  Future<void> reloadAfterSync() async {
    _ref.invalidate(settingsProvider);
    await _ref.read(settingsProvider.future);
    await _reload();
  }

  /// Alarms already in the system keep the mode they were scheduled with, so
  /// granting exact alarms only takes effect once they are laid down again.
  Future<void> refreshNotifications() => _syncNotifications();

  Future<void> _syncNotifications() async {
    final AppSettings? settings = _ref.read(settingsProvider).value;
    final ScheduleEngine? engine = _ref.read(scheduleEngineProvider);
    if (settings == null || engine == null) return;
    await NotificationService.instance.rescheduleAll(
      settings: settings,
      upcoming: engine.upcomingSessions(),
      stats: _ref.read(statsProvider),
    );
  }

  // backup -------------------------------------------------------------------

  /// Guards against the home screen's post-frame callback firing again while
  /// the first write is still in flight — it runs on every build, not only on
  /// launch, and two concurrent exports would race on the same filename.
  bool _autoBackupRunning = false;

  /// Writes today's automatic backup if one is due, then records when.
  ///
  /// Called from the home screen rather than from [_refresh], because a backup
  /// per mutation would serialise the whole database on every attendance tap
  /// for a freshness gain measured in hours.
  Future<void> maybeRunAutoBackup() async {
    if (_autoBackupRunning) return;
    final AppSettings? settings = _ref.read(settingsProvider).value;
    if (settings == null || !settings.autoBackupEnabled) return;

    _autoBackupRunning = true;
    try {
      final bool written =
          await _ref.read(backupServiceProvider).runAutoBackup(
                enabled: settings.autoBackupEnabled,
                lastAt: settings.lastAutoBackupAt,
                folderUri: settings.backupFolderUri,
              );
      if (!written) return;
      await _ref
          .read(settingsProvider.notifier)
          .save(settings.copyWith(lastAutoBackupAt: DateTime.now()));
    } catch (error) {
      // A failed backup must not take the home screen down with it. The next
      // launch tries again, and the stamp is only written on success so a
      // failure does not count as today's backup.
      debugPrint('Zeolite: auto backup failed: $error');
    } finally {
      _autoBackupRunning = false;
    }
  }

  /// Runs the first sync against an account that already had data, with the
  /// merge screen's decisions.
  ///
  /// Lives here rather than on the screen so it lands under the same snapshot
  /// every other import does: a merge can restate history, and one Undo has to
  /// put all of it back — the rows brought down and the ones sent up alike.
  Future<SyncRunResult> applySyncMerge(
    SyncCoordinator coordinator,
    Map<String, SyncSide> decisions,
  ) async {
    final DatabaseSnapshot before = await _repo.snapshot();
    final SyncRunResult result =
        await coordinator.run(force: true, merge: decisions);
    await reloadAfterSync();
    _mergeUndoToken = _undo.arm(before);
    _mergeUndoTarget = coordinator.target.id;
    return result;
  }

  /// Undoing a merge has to take the ledger with it. `remote_links` is outside
  /// the snapshot by design, so a plain restore would put the local rows back
  /// while leaving links that say the account holds them — and the next run
  /// would read those rows as deleted here and archive the account's copies.
  /// Forgetting the ledger instead returns the pair to "not yet reconciled",
  /// which is the state the merge screen is for.
  int? _mergeUndoToken;
  String? _mergeUndoTarget;

  // undo ---------------------------------------------------------------------

  int? get pendingUndoToken => _undo.pendingToken;

  /// Puts the database back as it stood before the action [token] belongs to.
  /// False once that offer has been overtaken, which is what stops a snackbar
  /// still on screen from undoing something it did not name.
  Future<bool> undo(int token) async {
    final DatabaseSnapshot? snapshot = _undo.take(token);
    if (snapshot == null) return false;
    await _repo.restore(snapshot);
    if (token == _mergeUndoToken && _mergeUndoTarget != null) {
      await _repo.deleteRemoteLinksFor(_mergeUndoTarget!);
    }
    await _refresh();
    return true;
  }

  // categories -------------------------------------------------------------

  Future<int> addCategory(ClassCategory category) async {
    final int id = await _repo.insertCategory(category);
    await _refresh();
    return id;
  }

  Future<void> updateCategory(ClassCategory category) async {
    await _repo.updateCategory(category);
    await _refresh();
  }

  /// Subjects in a deleted category keep all their data and fall back to the
  /// global default class length.
  Future<void> deleteCategory(int id) async {
    await _repo.deleteCategory(id);
    await _refresh();
  }

  Future<int> countSubjectsInCategory(int id) =>
      _repo.countSubjectsInCategory(id);

  // rooms ------------------------------------------------------------------

  Future<int> addRoom(Room room) async {
    final int id = await _repo.insertRoom(room);
    await _refresh();
    return id;
  }

  Future<void> updateRoom(Room room) async {
    await _repo.updateRoom(room);
    await _refresh();
  }

  /// Only forgets the suggestion. Classes already assigned this room keep it,
  /// because the room is stored on the class as text.
  Future<void> deleteRoom(int id) async {
    await _repo.deleteRoom(id);
    await _refresh();
  }

  // subjects ---------------------------------------------------------------

  Future<int> addSubject(Subject subject) async {
    final int id = await _repo.insertSubject(subject);
    await _refresh();
    return id;
  }

  Future<void> updateSubject(Subject subject) async {
    await _repo.updateSubject(subject);
    await _refresh();
  }

  Future<void> deleteSubject(int id) async {
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.deleteSubject(id);
    await _refresh();
    _undo.arm(before);
  }

  // recurring slots --------------------------------------------------------

  Future<void> addSlot(ClassSlot slot) async {
    await _repo.insertSlot(slot);
    await _refresh();
  }

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
    final TimetableData? data = _ref.read(timetableProvider).value;
    if (data == null || result.classes.isEmpty) return;

    final DatabaseSnapshot before = await _repo.snapshot();

    final Map<String, int> idByName = <String, int>{
      for (final Subject subject in data.subjects)
        if (subject.id != null) subject.name.trim().toLowerCase(): subject.id!,
    };

    final List<String> fresh = result.subjectNames
        .where((String name) => !idByName.containsKey(name.toLowerCase()))
        .toList();

    final List<int> palette = AppColors.subjectPalette;
    final List<int> ids = await _repo.insertSubjects(<Subject>[
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

    final DateTime start =
        _ref.read(settingsProvider).value?.semesterStart ?? Dates.today();

    await _repo.insertSlots(<ClassSlot>[
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

    final Set<String> known =
        data.rooms.map((Room room) => room.name.toLowerCase()).toSet();
    for (final String room in result.roomNames) {
      if (known.add(room.toLowerCase())) {
        await _repo.insertRoom(Room(name: room));
      }
    }

    await _refresh();
    _undo.arm(before);
  }

  /// Writes a portal's per-subject figures onto the subjects they name.
  ///
  /// Additive in the same way the paste import is: a row the user left out of
  /// [decisions] is not touched at all, and the whole thing sits under one undo
  /// snapshot. [TotalsDecision.clearMarks] drops that subject's term marks
  /// first, for the reason given on [TotalsMatch.overlap].
  Future<int> importAttendanceTotals(List<TotalsDecision> decisions) async {
    final TimetableData? data = _ref.read(timetableProvider).value;
    if (data == null || decisions.isEmpty) return 0;

    final DatabaseSnapshot before = await _repo.snapshot();
    final AppSettings settings =
        _ref.read(settingsProvider).value ?? const AppSettings();
    final List<int> palette = AppColors.subjectPalette;

    int created = 0;
    for (final TotalsDecision decision in decisions) {
      final TotalsRow row = decision.row;
      final int? id = decision.subjectId;
      if (id == null) {
        await _repo.insertSubject(
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
        await _repo.clearAttendanceBetween(
          id,
          settings.semesterStart ?? DateTime.utc(1970),
          settings.semesterEnd ?? DateTime.utc(2999),
        );
      }
      final Subject? existing = data.subjects
          .where((Subject s) => s.id == id)
          .firstOrNull;
      // Gone since the preview was built, so there is nothing to write onto.
      if (existing == null) continue;
      await _repo.updateSubject(
        existing.copyWith(
          priorHeld: row.held,
          priorAttended: row.attended,
          expectedTotal: row.expectedTotal,
        ),
      );
    }

    await _refresh();
    _undo.arm(before);
    return decisions.length;
  }

  /// Writes a Notion class log as marks against the subjects it names.
  ///
  /// Additive like the other two imports: a subject the user unticked is not
  /// touched. A [NotionMatch.overlap] subject has its marks inside the
  /// export's own span cleared first — the export is the whole truth for those
  /// dates, so keeping both would double the term.
  Future<int> importNotionLog(List<NotionPlanSubject> chosen) async {
    final TimetableData? data = _ref.read(timetableProvider).value;
    if (data == null || chosen.isEmpty) return 0;

    final DatabaseSnapshot before = await _repo.snapshot();
    final List<int> palette = AppColors.subjectPalette;

    // A tag per label the file actually uses, matched against the user's own
    // list first so an import never makes a second "Proxy".
    final Map<String, int> tagIds = <String, int>{};
    for (final NotionPlanSubject planned in chosen) {
      for (final NotionPlacement placed in planned.placements) {
        final String? name = placed.row.tagName;
        if (name == null || tagIds.containsKey(name)) continue;
        final Tag? existing = data.tags
            .where((Tag t) =>
                t.name.trim().toLowerCase() == name.toLowerCase())
            .firstOrNull;
        tagIds[name] =
            existing?.id ?? await _repo.insertTag(Tag(name: name));
      }
    }

    final List<AttendanceRecord> records = <AttendanceRecord>[];
    int created = 0;

    for (final NotionPlanSubject planned in chosen) {
      if (planned.placements.isEmpty) continue;

      int? id = planned.subject?.id;
      if (id == null) {
        id = await _repo.insertSubject(
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
            .map((NotionPlacement p) => p.row.date)
            .toList()
          ..sort();
        await _repo.clearAttendanceBetween(id, dates.first, dates.last);
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

    await _repo.setManyAttendance(records);
    await _refresh();
    _undo.arm(before);
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

  Future<void> updateSlot(ClassSlot slot) async {
    await _repo.updateSlot(slot);
    await _refresh();
  }

  /// Deletes the rule and every future week it would have produced.
  ///
  /// Attendance already marked against it survives: marks are keyed by
  /// `(subject, date, start time)` and have no relationship to `class_slots`,
  /// so they keep counting and stay reachable in the subject's attendance log,
  /// flagged as orphaned.
  Future<void> deleteSlot(int id) async {
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.deleteSlot(id);
    await _refresh();
    _undo.arm(before);
  }

  /// Deletes the rule *and* the attendance recorded against it — the
  /// destructive half of the choice offered when a class is removed. Marks are
  /// matched by [ClassSlot.covers], having no slot id to follow.
  Future<void> deleteSlotAndMarks(ClassSlot slot) async {
    final int? id = slot.id;
    if (id == null) return;
    final DatabaseSnapshot before = await _repo.snapshot();
    final List<AttendanceRecord> records =
        _ref.read(timetableProvider).value?.records ?? <AttendanceRecord>[];
    for (final AttendanceRecord record in records) {
      if (!slot.covers(record)) continue;
      await _repo.clearAttendance(
        record.subjectId,
        record.date,
        record.startMinutes,
      );
    }
    await _repo.deleteSlot(id);
    await _refresh();
    _undo.arm(before);
  }

  /// Keeps history intact but stops the class recurring from [date] on.
  Future<void> endSlotFrom(int slotId, DateTime date) async {
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.endSlotBefore(slotId, date);
    await _refresh();
    _undo.arm(before);
  }

  // one-off classes --------------------------------------------------------

  Future<void> addExtraClass(ExtraClass extra) async {
    await _repo.insertExtraClass(extra);
    await _refresh();
  }

  /// Moving a one-off class leaves any mark already made against it behind at
  /// the old `(subject, date, start time)`, exactly as editing a weekly rule
  /// does. The attendance log surfaces those as orphaned rather than deleting
  /// history the user did record.
  Future<void> updateExtraClass(ExtraClass extra) async {
    await _repo.updateExtraClass(extra);
    await _refresh();
  }

  Future<void> deleteExtraClass(int id) async {
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.deleteExtraClass(id);
    await _refresh();
    _undo.arm(before);
  }

  // tags --------------------------------------------------------------------

  Future<int> addTag(Tag tag) async {
    final int id = await _repo.insertTag(tag);
    await _refresh();
    return id;
  }

  Future<void> updateTag(Tag tag) async {
    await _repo.updateTag(tag);
    await _refresh();
  }

  Future<void> deleteTag(int id) async {
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.deleteTag(id);
    await _refresh();
    _undo.arm(before);
  }

  Future<int> countMarksWithTag(int id) => _repo.countMarksWithTag(id);

  // attendance -------------------------------------------------------------

  /// Marks one occurrence. Tapping the status it already has clears the mark,
  /// which makes the Today screen fully reversible with a single gesture.
  Future<void> mark(ClassSession session, AttendanceStatus status) async {
    final int? subjectId = session.subject.id;
    if (subjectId == null) return;
    await setStatusAt(
      subjectId: subjectId,
      date: session.date,
      startMinutes: session.startMinutes,
      current: session.status,
      status: status,
      weight: session.record?.weight ?? session.weight,
      // Carried across a status change on purpose. `setAttendance` replaces the
      // row, so without this, correcting Present to Absent would silently drop
      // the tag — and the tag describes the class, not the verdict. Clearing
      // the mark still takes the tag with it, which is the one case where the
      // occurrence genuinely has nothing left to label.
      tagId: session.record?.tagId,
    );
  }

  /// The same toggle rule addressed by natural key instead of by session.
  ///
  /// The attendance log needs this: a mark left behind by a deleted rule has no
  /// [ClassSession] to pass, but must still be correctable. Keeping one
  /// implementation means the "tap the current status to clear it" behaviour
  /// cannot drift between the two screens.
  Future<void> setStatusAt({
    required int subjectId,
    required DateTime date,
    required int startMinutes,
    required AttendanceStatus? current,
    required AttendanceStatus status,
    int weight = 1,
    int? tagId,
  }) async {
    if (current == status) {
      await clearStatusAt(
        subjectId: subjectId,
        date: date,
        startMinutes: startMinutes,
      );
      return;
    }
    await _repo.setAttendance(
      AttendanceRecord(
        subjectId: subjectId,
        date: date,
        startMinutes: startMinutes,
        status: status,
        weight: weight,
        tagId: tagId,
        markedAt: DateTime.now(),
      ),
    );
    await _refresh();
  }

  /// Attaches or removes the tag on a marked occurrence, leaving the status
  /// alone. Passing the tag it already has clears it, same as the status
  /// buttons.
  ///
  /// Reads the record first because `setAttendance` replaces the whole row — a
  /// record built from a tag alone would drop the status and the mark time.
  Future<void> setTagAt({
    required int subjectId,
    required DateTime date,
    required int startMinutes,
    required int? tagId,
  }) async {
    final AttendanceRecord? current = await _repo.getAttendanceAt(
      subjectId,
      date,
      startMinutes,
    );
    // Nothing to tag: a tag describes a mark, so there is no meaning in one
    // floating on an unmarked class.
    if (current == null) return;
    final bool clearing = tagId == null || current.tagId == tagId;
    await _repo.setAttendance(
      current.copyWith(tagId: clearing ? null : tagId, clearTag: clearing),
    );
    await _refresh();
  }

  /// Removes a mark outright, by natural key.
  ///
  /// The attendance log offers this explicitly for a mark whose weekly class
  /// has been deleted: clearing it by tapping its own status again works, but
  /// is not something anyone would guess at for a row they did not create.
  Future<void> clearStatusAt({
    required int subjectId,
    required DateTime date,
    required int startMinutes,
  }) async {
    await _repo.clearAttendance(subjectId, date, startMinutes);
    await _refresh();
  }

  /// [clearStatusAt] addressed by session rather than by natural key.
  Future<void> clearMark(ClassSession session) async {
    final int? subjectId = session.subject.id;
    if (subjectId == null) return;
    await clearStatusAt(
      subjectId: subjectId,
      date: session.date,
      startMinutes: session.startMinutes,
    );
  }

  /// Marks every unmarked class in [sessions] with [status] in one batch.
  Future<int> markAll(
    List<ClassSession> sessions,
    AttendanceStatus status,
  ) async {
    final List<AttendanceRecord> records = <AttendanceRecord>[];
    for (final ClassSession session in sessions) {
      final int? subjectId = session.subject.id;
      if (subjectId == null || session.isMarked) continue;
      records.add(
        AttendanceRecord(
          subjectId: subjectId,
          date: session.date,
          startMinutes: session.startMinutes,
          status: status,
          weight: session.weight,
          markedAt: DateTime.now(),
        ),
      );
    }
    if (records.isEmpty) return 0;
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.setManyAttendance(records);
    await _refresh();
    _undo.arm(before);
    return records.length;
  }

  // holidays ---------------------------------------------------------------

  Future<void> addHoliday(Holiday holiday) async {
    await _repo.insertHoliday(holiday);
    await _refresh();
  }

  /// One refresh for the whole range — a two-week break would otherwise
  /// rebuild the engine, the day lists and the stats fourteen times.
  Future<void> addHolidays(List<Holiday> holidays) async {
    if (holidays.isEmpty) return;
    await _repo.insertHolidays(holidays);
    await _refresh();
  }

  Future<void> deleteHoliday(int id) async {
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.deleteHoliday(id);
    await _refresh();
    _undo.arm(before);
  }

  Future<void> deleteHolidays(List<int> ids) async {
    if (ids.isEmpty) return;
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.deleteHolidays(ids);
    await _refresh();
    _undo.arm(before);
  }

  // admin ------------------------------------------------------------------

  Future<void> resetEverything() async {
    final DatabaseSnapshot before = await _repo.snapshot();
    await _repo.clearAll();
    await NotificationService.instance.cancelAll();
    await _refresh();
    _undo.arm(before);
  }

  /// Awaited for the same reason as [reloadAfterSync], and it matters more
  /// here: a restore can move the semester dates the reminders hang off.
  Future<void> reloadAfterImport() async {
    _ref.invalidate(settingsProvider);
    await _ref.read(settingsProvider.future);
    await _refresh();
  }
}

final actionsProvider = Provider<TimetableActions>(
  (ref) => TimetableActions(ref),
);
