import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../data/models/slot_override.dart';
import '../data/models/subject.dart';
import '../data/models/tag.dart';
import '../data/settings/app_settings.dart';
import '../domain/attendance_log.dart';
import '../domain/attendance_stats.dart';
import '../domain/class_weight.dart';
import '../domain/day_grid.dart';
import '../domain/schedule_engine.dart';
import '../domain/sync/sync_target.dart';
import '../domain/tag_stats.dart';
import '../services/analytics_service.dart';
import '../services/backup_folder.dart';
import '../services/backup_service.dart';
import '../services/launcher_icon_service.dart';
import '../services/notification_service.dart';

import 'notion_sync_providers.dart';
import 'sync_providers.dart';

export 'actions/action_core.dart';
export 'actions/attendance_actions.dart';
export 'actions/data_actions.dart';
export 'actions/import_actions.dart';
export 'actions/schedule_actions.dart';
export 'actions/subject_actions.dart';

import 'actions/action_core.dart';
import 'actions/attendance_actions.dart';
import 'actions/data_actions.dart';
import 'actions/import_actions.dart';
import 'actions/schedule_actions.dart';
import 'actions/subject_actions.dart';

// ---------------------------------------------------------------- singletons

final repositoryProvider = Provider<ZeoliteRepository>(
  (ref) => ZeoliteRepository(),
);

final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(),
);

/// Null where Firebase did not come up, which is also every widget test —
/// `MaterialApp` takes an empty observer list rather than a broken one.
final analyticsObserverProvider = Provider<FirebaseAnalyticsObserver?>(
  (ref) => Firebase.apps.isEmpty
      ? null
      : FirebaseAnalyticsObserver(
          analytics: FirebaseAnalytics.instance,
          // The shell sits at '/', which [RootShell] already reports as
          // whichever tab is showing. Without this every launch files a screen
          // called '/' alongside the real one.
          nameExtractor: (RouteSettings route) =>
              route.name == '/' ? null : route.name,
        ),
);

/// [NoAnalytics] where Firebase did not come up. `main` lets that failure pass
/// so the app still runs offline, and a measurement is not the thing to break
/// it — tests get the same, with no Firebase to initialise.
final analyticsProvider = Provider<Analytics>(
  (ref) => Firebase.apps.isEmpty
      ? const NoAnalytics()
      : FirebaseAnalyticsService(FirebaseAnalytics.instance),
);

/// Whether the chosen backup folder can still be written to. Asked when
/// Settings draws rather than remembered, since the grant can go while the app
/// is not looking.
final backupFolderUsableProvider = FutureProvider<bool>((ref) async {
  final String? uri = ref.watch(settingsProvider).value?.backupFolderUri;
  if (uri == null) return false;
  return BackupFolder().isUsable(uri);
});

/// The notification plugin only exists on a device, so tests swap this for one
/// that schedules nothing.
final notificationsProvider = Provider<NotificationService>(
  (ref) => NotificationService.instance,
);

/// Whether class reminders can fire to the minute. Asked when Settings draws,
/// since the permission is granted on a system screen the app cannot watch.
final exactAlarmsProvider = FutureProvider<bool>(
  (ref) => ref.watch(notificationsProvider).canScheduleExactly(),
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    ref.watch(repositoryProvider),
    ref.watch(settingsServiceProvider),
  ),
);

final launcherIconServiceProvider =
    Provider<LauncherIconService>((ref) => const LauncherIconService());

final launcherIconProvider =
    AsyncNotifierProvider<LauncherIconController, LauncherIcon>(
  LauncherIconController.new,
);

class LauncherIconController extends AsyncNotifier<LauncherIcon> {
  @override
  Future<LauncherIcon> build() =>
      ref.watch(launcherIconServiceProvider).current();

  /// Android may kill the process to apply this, so nothing is queued behind
  /// it — the state is set first so the picker is correct if the app survives,
  /// and read again from the platform on the next launch if it does not.
  Future<void> select(LauncherIcon icon) async {
    if (state.value == icon) return;
    state = AsyncData<LauncherIcon>(icon);
    await ref.read(launcherIconServiceProvider).select(icon);
  }
}

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

final settingsProvider = AsyncNotifierProvider<SettingsController, AppSettings>(
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
    this.overrides = const <SlotOverride>[],
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

  /// The weeks that depart from their rule. Defaulted because a timetable with
  /// none is the normal case and every pre-v13 install has exactly that.
  final List<SlotOverride> overrides;

  bool get isEmpty => subjects.isEmpty;

  /// The exception this rule carries on [date], or null when the week follows
  /// the rule like every other.
  SlotOverride? overrideOn(int? slotId, DateTime date) {
    if (slotId == null) return null;
    final int key = Dates.keyOf(date);
    for (final SlotOverride override in overrides) {
      if (override.slotId == slotId && Dates.keyOf(override.date) == key) {
        return override;
      }
    }
    return null;
  }

  bool hasOverridesFor(int? slotId) =>
      slotId != null && overrides.any((SlotOverride o) => o.slotId == slotId);

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
  final List<SlotOverride> overrides = await repo.getSlotOverrides();
  final List<Room> rooms = await repo.getRooms();
  final List<Tag> tags = await repo.getTags();
  return TimetableData(
    categories: categories,
    subjects: subjects,
    slots: slots,
    extras: extras,
    holidays: holidays,
    records: records,
    overrides: overrides,
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
    overrides: data.overrides,
    semesterStart: settings?.semesterStart,
    semesterEnd: settings?.semesterEnd,
  );
});

/// The day currently shown on the Today screen.
final selectedDateProvider = NotifierProvider<SelectedDateController, DateTime>(
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
final visibleWeekProvider = NotifierProvider<VisibleWeekController, DateTime>(
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

  void toggle() => state = state == HomeView.day ? HomeView.grid : HomeView.day;
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
        cancelledCounts: settings?.cancelledCountsAsAttended ?? false,
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

// ------------------------------------------------------------ navigation

/// The selected bottom-navigation tab.
///
/// Held here rather than in the shell's own state because a tapped
/// notification has to be able to change it from outside the widget tree.
class SelectedTabController extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final selectedTabProvider =
    NotifierProvider<SelectedTabController, int>(SelectedTabController.new);

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
/// two hours where a Lecture gets one, without asking every time.
final defaultDurationProvider =
    Provider.family<int, int?>((ref, int? subjectId) {
  final int fallback =
      ref.watch(settingsProvider).value?.defaultClassDurationMinutes ?? 60;
  final TimetableData? data = ref.watch(timetableProvider).value;
  if (data == null || subjectId == null) return fallback;
  final ClassCategory? category = data.categoryFor(data.subjectById(subjectId));
  return category?.defaultDurationMinutes ?? fallback;
});

/// [weightFor] against the subject's own category. Shaped like
/// [defaultDurationProvider] because it answers the same kind of question off
/// the same category.
final defaultWeightProvider = Provider.family<int, int?>((ref, int? subjectId) {
  final TimetableData? data = ref.watch(timetableProvider).value;
  if (data == null || subjectId == null) return 1;
  return weightFor(data.categoryFor(data.subjectById(subjectId)));
});

/// Says *why* a class came out the length it did — "Lab · 2 blocks · 1h 40m",
/// or "no category · 1h" when the global fallback was used.
///
/// Without this the two rules are indistinguishable on screen, which is how a
/// subject that was never given a category reads as a broken feature rather
/// than as a subject that was never given a category.
final defaultDurationLabelProvider = Provider.family<String, int?>(
  (ref, int? subjectId) => ref.watch(
    classLengthLabelProvider((subjectId: subjectId, categoryId: null)),
  ),
);

/// [defaultDurationLabelProvider] for a class with a type of its own, which
/// is what its length then follows.
final classLengthLabelProvider =
    Provider.family<String, ({int? subjectId, int? categoryId})>((ref, key) {
  final DayGrid grid = ref.watch(dayGridProvider);
  final TimetableData? data = ref.watch(timetableProvider).value;
  final ClassCategory? own = data?.categoryById(key.categoryId);
  final int minutes = own?.defaultDurationMinutes ??
      ref.watch(defaultDurationProvider(key.subjectId));
  final ClassCategory? category =
      own ?? data?.categoryFor(data.subjectById(key.subjectId));

  final List<String> parts = <String>[category?.name ?? 'no category'];
  if (grid.isWholeBlocks(minutes)) {
    final int blocks = grid.blocksFor(minutes);
    parts.add('$blocks ${blocks == 1 ? 'block' : 'blocks'}');
  }
  parts.add(Clock.formatDuration(minutes));
  return parts.join(' · ');
});

// ------------------------------------------------------------------ actions

/// Split by what they touch rather than gathered on one object: every action
/// shares [ActionCore], so one refresh and one Undo offer still cover them all.
final actionCoreProvider = Provider<ActionCore>((ref) => ActionCore(ref));

final subjectActionsProvider = Provider<SubjectActions>(
  (ref) => SubjectActions(ref.read(actionCoreProvider)),
);

final scheduleActionsProvider = Provider<ScheduleActions>(
  (ref) => ScheduleActions(ref.read(actionCoreProvider)),
);

final attendanceActionsProvider = Provider<AttendanceActions>(
  (ref) => AttendanceActions(ref.read(actionCoreProvider)),
);

final importActionsProvider = Provider<ImportActions>(
  (ref) => ImportActions(ref.read(actionCoreProvider)),
);

final dataActionsProvider = Provider<DataActions>(
  (ref) => DataActions(ref.read(actionCoreProvider)),
);
