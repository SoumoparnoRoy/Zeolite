import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/date_utils.dart';
import '../../domain/day_grid.dart';

/// Which theme the app renders in.
///
/// Persisted by `name` rather than index so reordering or inserting a value
/// here can never silently repoint an existing user's choice at a different
/// theme.
enum AppThemeMode {
  system,
  light,
  dark;

  static AppThemeMode fromName(String? name) {
    for (final AppThemeMode mode in AppThemeMode.values) {
      if (mode.name == name) return mode;
    }
    return AppThemeMode.dark;
  }

  String get label => switch (this) {
        AppThemeMode.system => 'Match system',
        AppThemeMode.light => 'Light',
        AppThemeMode.dark => 'Dark',
      };
}

/// User preferences: semester bounds, attendance target and notification
/// choices. Small scalar values, so they live in SharedPreferences rather than
/// the database.
@immutable
class AppSettings {
  const AppSettings({
    this.semesterStart,
    this.semesterEnd,
    this.targetPercent = 75,
    this.defaultClassDurationMinutes = 60,
    this.dayStartMinutes = 9 * 60,
    this.dayEndMinutes = 17 * 60,
    this.blockMinutes = 0,
    this.breakAfterBlock = 0,
    this.breakMinutes = 0,
    this.use24HourTime = false,
    this.themeMode = AppThemeMode.dark,
    this.notificationsEnabled = true,
    this.inAppAlerts = true,
    this.notifyBeforeClass = true,
    this.notifyLeadMinutes = 15,
    this.notifyEveningReminder = true,
    this.eveningReminderMinutes = 20 * 60,
    this.notifyAttendanceDanger = true,
    this.autoBackupEnabled = false,
    this.lastAutoBackupAt,
    this.scheduleChangedAt,
    this.backupFolderUri,
    this.backupFolderName,
    this.onboarded = false,
  });

  final DateTime? semesterStart;
  final DateTime? semesterEnd;

  /// Global requirement, e.g. 75. Subjects may override this.
  final double targetPercent;

  /// Fallback class length, used when a subject has no category. Picking a
  /// start time fills the end time in from this.
  final int defaultClassDurationMinutes;

  /// The three numbers that describe a period-based day: when teaching starts,
  /// when it ends, and how long one lecture block runs. Everything else about
  /// the grid — how many blocks there are, where each one sits — is derived by
  /// [DayGrid], so there is nothing to keep in sync.
  ///
  /// [blockMinutes] of 0 means the day has not been divided up, which is the
  /// state every existing install starts in.
  final int dayStartMinutes;
  final int dayEndMinutes;
  final int blockMinutes;

  /// A mid-day break, held as the block it follows rather than a clock time so
  /// it cannot land halfway through a lecture. Zero means no break.
  final int breakAfterBlock;
  final int breakMinutes;

  final bool use24HourTime;

  /// The app has always been dark-first, so an existing install keeps that
  /// look after updating; light and system are opt-in.
  final AppThemeMode themeMode;

  /// Master switch. When false nothing is posted to the system tray at all,
  /// whatever the three per-type flags below say — those keep their values so
  /// switching back on restores the previous choices rather than resetting
  /// them.
  final bool notificationsEnabled;

  /// Surface alerts inside the app when the system notification for them is
  /// switched off. This is what stops "notifications off" from also meaning
  /// "never tell me I am about to drop below target".
  final bool inAppAlerts;

  final bool notifyBeforeClass;
  final int notifyLeadMinutes;

  final bool notifyEveningReminder;

  /// Minutes since midnight for the evening "mark your attendance" nudge.
  final int eveningReminderMinutes;

  final bool notifyAttendanceDanger;

  /// Off by default: it writes a file on its own, and a feature that starts
  /// doing that without being asked is a feature the user did not consent to.
  final bool autoBackupEnabled;

  /// When the last automatic backup was written. Device state rather than user
  /// data, which is why it is kept out of the export — restoring it onto
  /// another phone would tell that phone a backup had already been taken.
  final DateTime? lastAutoBackupAt;

  /// When a setting that shapes the timetable was last changed here.
  ///
  /// Exists only so two signed-in devices can settle a disagreement about the
  /// semester dates by time rather than by whichever syncs last. Device
  /// preferences do not move it, because they never travel.
  final DateTime? scheduleChangedAt;

  /// A persisted SAF tree URI; null means the app's own folder. Out of the
  /// export like [lastAutoBackupAt], and for a sharper reason: a grant belongs
  /// to this install, so restoring one elsewhere points at an unwritable
  /// folder.
  final String? backupFolderUri;

  /// Stored so the Settings row draws without a platform call per build.
  final String? backupFolderName;

  final bool onboarded;

  bool get hasBackupFolder => backupFolderUri != null;

  double get targetRatio => targetPercent / 100.0;

  DayGrid get dayGrid => DayGrid(
        dayStartMinutes: dayStartMinutes,
        dayEndMinutes: dayEndMinutes,
        blockMinutes: blockMinutes,
        breakAfterBlock: breakAfterBlock,
        breakMinutes: breakMinutes,
      );

  /// A type only reaches the system tray when the master switch and its own
  /// flag are both on.
  bool get classRemindersActive => notificationsEnabled && notifyBeforeClass;
  bool get eveningReminderActive =>
      notificationsEnabled && notifyEveningReminder;
  bool get dangerAlertsActive =>
      notificationsEnabled && notifyAttendanceDanger;

  /// Attendance warnings are not reaching the tray, so the app shows them
  /// itself instead of dropping them silently.
  bool get showDangerInApp => inAppAlerts && !dangerAlertsActive;

  bool get hasSemester => semesterStart != null && semesterEnd != null;

  /// Whether a mark on [date] counts towards this term. Inclusive at both
  /// ends, and with no dates set there is no window, so everything counts.
  bool countsInTerm(DateTime date) {
    if (!hasSemester) return true;
    final DateTime day = Dates.dayOf(date);
    return !day.isBefore(Dates.dayOf(semesterStart!)) &&
        !day.isAfter(Dates.dayOf(semesterEnd!));
  }

  /// How far through the term you are, 0..1.
  double get semesterProgress {
    if (!hasSemester) return 0;
    final int total = Dates.daysBetween(semesterStart!, semesterEnd!);
    if (total <= 0) return 1;
    final int done = Dates.daysBetween(semesterStart!, Dates.today());
    return (done / total).clamp(0.0, 1.0);
  }

  int get daysLeftInSemester {
    if (semesterEnd == null) return 0;
    final int days = Dates.daysBetween(Dates.today(), semesterEnd!);
    return days < 0 ? 0 : days;
  }

  AppSettings copyWith({
    DateTime? semesterStart,
    DateTime? semesterEnd,
    double? targetPercent,
    int? defaultClassDurationMinutes,
    int? dayStartMinutes,
    int? dayEndMinutes,
    int? blockMinutes,
    int? breakAfterBlock,
    int? breakMinutes,
    bool? use24HourTime,
    AppThemeMode? themeMode,
    bool? notificationsEnabled,
    bool? inAppAlerts,
    bool? notifyBeforeClass,
    int? notifyLeadMinutes,
    bool? notifyEveningReminder,
    int? eveningReminderMinutes,
    bool? notifyAttendanceDanger,
    bool? autoBackupEnabled,
    DateTime? lastAutoBackupAt,
    DateTime? scheduleChangedAt,
    String? backupFolderUri,
    String? backupFolderName,
    bool clearBackupFolder = false,
    bool? onboarded,
  }) {
    return AppSettings(
      semesterStart: semesterStart ?? this.semesterStart,
      semesterEnd: semesterEnd ?? this.semesterEnd,
      targetPercent: targetPercent ?? this.targetPercent,
      defaultClassDurationMinutes:
          defaultClassDurationMinutes ?? this.defaultClassDurationMinutes,
      dayStartMinutes: dayStartMinutes ?? this.dayStartMinutes,
      dayEndMinutes: dayEndMinutes ?? this.dayEndMinutes,
      blockMinutes: blockMinutes ?? this.blockMinutes,
      breakAfterBlock: breakAfterBlock ?? this.breakAfterBlock,
      breakMinutes: breakMinutes ?? this.breakMinutes,
      use24HourTime: use24HourTime ?? this.use24HourTime,
      themeMode: themeMode ?? this.themeMode,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      inAppAlerts: inAppAlerts ?? this.inAppAlerts,
      notifyBeforeClass: notifyBeforeClass ?? this.notifyBeforeClass,
      notifyLeadMinutes: notifyLeadMinutes ?? this.notifyLeadMinutes,
      notifyEveningReminder:
          notifyEveningReminder ?? this.notifyEveningReminder,
      eveningReminderMinutes:
          eveningReminderMinutes ?? this.eveningReminderMinutes,
      notifyAttendanceDanger:
          notifyAttendanceDanger ?? this.notifyAttendanceDanger,
      autoBackupEnabled: autoBackupEnabled ?? this.autoBackupEnabled,
      lastAutoBackupAt: lastAutoBackupAt ?? this.lastAutoBackupAt,
      scheduleChangedAt: scheduleChangedAt ?? this.scheduleChangedAt,
      // Choosing a folder and clearing one both have to be expressible, and
      // `?? this` cannot say "set this back to null".
      backupFolderUri:
          clearBackupFolder ? null : backupFolderUri ?? this.backupFolderUri,
      backupFolderName:
          clearBackupFolder ? null : backupFolderName ?? this.backupFolderName,
      onboarded: onboarded ?? this.onboarded,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'semesterStart':
            semesterStart == null ? null : Dates.keyOf(semesterStart!),
        'semesterEnd': semesterEnd == null ? null : Dates.keyOf(semesterEnd!),
        'targetPercent': targetPercent,
        'defaultClassDurationMinutes': defaultClassDurationMinutes,
        'dayStartMinutes': dayStartMinutes,
        'dayEndMinutes': dayEndMinutes,
        'blockMinutes': blockMinutes,
        'breakAfterBlock': breakAfterBlock,
        'breakMinutes': breakMinutes,
        'use24HourTime': use24HourTime,
        'themeMode': themeMode.name,
        'notificationsEnabled': notificationsEnabled,
        'inAppAlerts': inAppAlerts,
        'notifyBeforeClass': notifyBeforeClass,
        'notifyLeadMinutes': notifyLeadMinutes,
        'notifyEveningReminder': notifyEveningReminder,
        'eveningReminderMinutes': eveningReminderMinutes,
        'notifyAttendanceDanger': notifyAttendanceDanger,
        'autoBackupEnabled': autoBackupEnabled,
      };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final int? start = (json['semesterStart'] as num?)?.toInt();
    final int? end = (json['semesterEnd'] as num?)?.toInt();
    return AppSettings(
      semesterStart: start == null ? null : Dates.fromKey(start),
      semesterEnd: end == null ? null : Dates.fromKey(end),
      targetPercent: (json['targetPercent'] as num?)?.toDouble() ?? 75,
      defaultClassDurationMinutes:
          (json['defaultClassDurationMinutes'] as num?)?.toInt() ?? 60,
      // A backup taken before the day grid existed restores as "not divided
      // up", which is how the app behaved when that backup was written.
      dayStartMinutes: (json['dayStartMinutes'] as num?)?.toInt() ?? 9 * 60,
      dayEndMinutes: (json['dayEndMinutes'] as num?)?.toInt() ?? 17 * 60,
      blockMinutes: (json['blockMinutes'] as num?)?.toInt() ?? 0,
      breakAfterBlock: (json['breakAfterBlock'] as num?)?.toInt() ?? 0,
      breakMinutes: (json['breakMinutes'] as num?)?.toInt() ?? 0,
      use24HourTime: json['use24HourTime'] as bool? ?? false,
      themeMode: AppThemeMode.fromName(json['themeMode'] as String?),
      // Backups written before these existed default to "on", which matches
      // how the app behaved when that backup was taken.
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      inAppAlerts: json['inAppAlerts'] as bool? ?? true,
      notifyBeforeClass: json['notifyBeforeClass'] as bool? ?? true,
      notifyLeadMinutes: (json['notifyLeadMinutes'] as num?)?.toInt() ?? 15,
      notifyEveningReminder: json['notifyEveningReminder'] as bool? ?? true,
      eveningReminderMinutes:
          (json['eveningReminderMinutes'] as num?)?.toInt() ?? 20 * 60,
      notifyAttendanceDanger: json['notifyAttendanceDanger'] as bool? ?? true,
      autoBackupEnabled: json['autoBackupEnabled'] as bool? ?? false,
      onboarded: true,
    );
  }
}

/// Reads and writes [AppSettings]. Keys are namespaced so a future feature can
/// share the same preference store without collisions.
class SettingsService {
  static const String _kSemesterStart = 'ut.semesterStart';
  static const String _kSemesterEnd = 'ut.semesterEnd';
  static const String _kTarget = 'ut.targetPercent';
  static const String _kDefaultDuration = 'ut.defaultClassDurationMinutes';
  static const String _kDayStart = 'ut.dayStartMinutes';
  static const String _kDayEnd = 'ut.dayEndMinutes';
  static const String _kBlockMinutes = 'ut.blockMinutes';
  static const String _kBreakAfterBlock = 'ut.breakAfterBlock';
  static const String _kBreakMinutes = 'ut.breakMinutes';
  static const String _kScheduleChangedAt = 'ut.scheduleChangedAt';
  static const String _k24h = 'ut.use24HourTime';
  static const String _kThemeMode = 'ut.themeMode';
  static const String _kNotificationsEnabled = 'ut.notificationsEnabled';
  static const String _kInAppAlerts = 'ut.inAppAlerts';
  static const String _kNotifyBefore = 'ut.notifyBeforeClass';
  static const String _kLead = 'ut.notifyLeadMinutes';
  static const String _kNotifyEvening = 'ut.notifyEveningReminder';
  static const String _kEveningMinutes = 'ut.eveningReminderMinutes';
  static const String _kNotifyDanger = 'ut.notifyAttendanceDanger';
  static const String _kAutoBackup = 'ut.autoBackup';
  static const String _kLastAutoBackup = 'ut.lastAutoBackup';
  static const String _kBackupFolderUri = 'ut.backupFolderUri';
  static const String _kBackupFolderName = 'ut.backupFolderName';
  static const String _kOnboarded = 'ut.onboarded';

  /// The modern, cache-free preferences API. `SharedPreferences.getInstance()`
  /// is a legacy surface that the plugin has flagged for deprecation.
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<AppSettings> load() async {
    final SharedPreferencesAsync prefs = _prefs;
    final int? start = await prefs.getInt(_kSemesterStart);
    final int? end = await prefs.getInt(_kSemesterEnd);
    return AppSettings(
      semesterStart: start == null ? null : Dates.fromKey(start),
      semesterEnd: end == null ? null : Dates.fromKey(end),
      targetPercent: await prefs.getDouble(_kTarget) ?? 75,
      defaultClassDurationMinutes:
          await prefs.getInt(_kDefaultDuration) ?? 60,
      dayStartMinutes: await prefs.getInt(_kDayStart) ?? 9 * 60,
      dayEndMinutes: await prefs.getInt(_kDayEnd) ?? 17 * 60,
      blockMinutes: await prefs.getInt(_kBlockMinutes) ?? 0,
      breakAfterBlock: await prefs.getInt(_kBreakAfterBlock) ?? 0,
      breakMinutes: await prefs.getInt(_kBreakMinutes) ?? 0,
      use24HourTime: await prefs.getBool(_k24h) ?? false,
      themeMode: AppThemeMode.fromName(await prefs.getString(_kThemeMode)),
      notificationsEnabled:
          await prefs.getBool(_kNotificationsEnabled) ?? true,
      inAppAlerts: await prefs.getBool(_kInAppAlerts) ?? true,
      notifyBeforeClass: await prefs.getBool(_kNotifyBefore) ?? true,
      notifyLeadMinutes: await prefs.getInt(_kLead) ?? 15,
      notifyEveningReminder: await prefs.getBool(_kNotifyEvening) ?? true,
      eveningReminderMinutes: await prefs.getInt(_kEveningMinutes) ?? 20 * 60,
      notifyAttendanceDanger: await prefs.getBool(_kNotifyDanger) ?? true,
      autoBackupEnabled: await prefs.getBool(_kAutoBackup) ?? false,
      lastAutoBackupAt: switch (await prefs.getInt(_kLastAutoBackup)) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        null => null,
      },
      scheduleChangedAt: switch (await prefs.getInt(_kScheduleChangedAt)) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        null => null,
      },
      backupFolderUri: await prefs.getString(_kBackupFolderUri),
      backupFolderName: await prefs.getString(_kBackupFolderName),
      onboarded: await prefs.getBool(_kOnboarded) ?? false,
    );
  }

  Future<void> save(AppSettings settings) async {
    final SharedPreferencesAsync prefs = _prefs;
    if (settings.semesterStart == null) {
      await prefs.remove(_kSemesterStart);
    } else {
      await prefs.setInt(_kSemesterStart, Dates.keyOf(settings.semesterStart!));
    }
    if (settings.semesterEnd == null) {
      await prefs.remove(_kSemesterEnd);
    } else {
      await prefs.setInt(_kSemesterEnd, Dates.keyOf(settings.semesterEnd!));
    }
    await prefs.setDouble(_kTarget, settings.targetPercent);
    await prefs.setInt(
      _kDefaultDuration,
      settings.defaultClassDurationMinutes,
    );
    await prefs.setInt(_kDayStart, settings.dayStartMinutes);
    await prefs.setInt(_kDayEnd, settings.dayEndMinutes);
    await prefs.setInt(_kBlockMinutes, settings.blockMinutes);
    await prefs.setInt(_kBreakAfterBlock, settings.breakAfterBlock);
    await prefs.setInt(_kBreakMinutes, settings.breakMinutes);
    await prefs.setBool(_k24h, settings.use24HourTime);
    await prefs.setString(_kThemeMode, settings.themeMode.name);
    await prefs.setBool(
      _kNotificationsEnabled,
      settings.notificationsEnabled,
    );
    await prefs.setBool(_kInAppAlerts, settings.inAppAlerts);
    await prefs.setBool(_kNotifyBefore, settings.notifyBeforeClass);
    await prefs.setInt(_kLead, settings.notifyLeadMinutes);
    await prefs.setBool(_kNotifyEvening, settings.notifyEveningReminder);
    await prefs.setInt(_kEveningMinutes, settings.eveningReminderMinutes);
    await prefs.setBool(_kNotifyDanger, settings.notifyAttendanceDanger);
    await prefs.setBool(_kAutoBackup, settings.autoBackupEnabled);
    if (settings.scheduleChangedAt == null) {
      await prefs.remove(_kScheduleChangedAt);
    } else {
      await prefs.setInt(
        _kScheduleChangedAt,
        settings.scheduleChangedAt!.millisecondsSinceEpoch,
      );
    }
    if (settings.lastAutoBackupAt == null) {
      await prefs.remove(_kLastAutoBackup);
    } else {
      await prefs.setInt(
        _kLastAutoBackup,
        settings.lastAutoBackupAt!.millisecondsSinceEpoch,
      );
    }
    if (settings.backupFolderUri == null) {
      await prefs.remove(_kBackupFolderUri);
      await prefs.remove(_kBackupFolderName);
    } else {
      await prefs.setString(_kBackupFolderUri, settings.backupFolderUri!);
      await prefs.setString(
        _kBackupFolderName,
        settings.backupFolderName ?? '',
      );
    }
    await prefs.setBool(_kOnboarded, settings.onboarded);
  }
}
