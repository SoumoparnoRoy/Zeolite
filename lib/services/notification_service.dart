import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/app_theme.dart';
import '../core/date_utils.dart';
import '../data/models/class_session.dart';
import '../data/settings/app_settings.dart';
import '../domain/attendance_stats.dart';

/// What to do about the attendance warning on this pass.
enum DangerAlert { raise, leave, clear }

/// [DangerAlert.warned] is what to record once the action has been carried out.
@immutable
class DangerDecision {
  const DangerDecision(this.action, this.warned);

  final DangerAlert action;
  final Set<int> warned;
}

/// The notification categories Android lets a user block one at a time.
enum TrayChannel { classes, reminders, alerts }

/// What Android lets through, as opposed to what the settings ask for. The
/// user can block either from the system screens, where the app is never told.
@immutable
class TrayAccess {
  const TrayAccess({
    this.appAllowed = true,
    this.blocked = const <TrayChannel>{},
  });

  /// Assumed until Android has answered, so nothing warns on a guess.
  static const TrayAccess open = TrayAccess();

  final bool appAllowed;
  final Set<TrayChannel> blocked;

  bool allows(TrayChannel channel) =>
      appAllowed && !blocked.contains(channel);

  /// Blocked on its own, while the app as a whole is allowed. With the app
  /// blocked the per-channel answer tells the user nothing new.
  bool blocksOnly(TrayChannel channel) =>
      appAllowed && blocked.contains(channel);
}

/// What to do with one day's evening reminder on this pass.
enum EveningReminder { schedule, refresh, cancel, leave }

/// All local notifications: class reminders, the evening "mark your
/// attendance" nudge, and attendance danger alerts.
///
/// Everything is scheduled on-device — no server, no push tokens. Android only
/// keeps a limited number of pending alarms, so class reminders are scheduled
/// as a rolling window (see [_maxClassReminders]) and refreshed whenever the
/// timetable changes.
class NotificationService {
  NotificationService._();

  @visibleForTesting
  NotificationService.forTesting();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;

  /// The payload of the notification the user last tapped, or null once the
  /// app has acted on it. A value rather than a stream because the tap that
  /// launches the app arrives during [init], before anything is listening.
  final ValueNotifier<String?> tappedPayload = ValueNotifier<String?>(null);

  /// Notification id ranges, kept apart so one feature never cancels another.
  static const int _classReminderBase = 100000;
  static const int _classEndReminderBase = 101000;
  static const int _eveningReminderBase = 3000;
  static const int _dangerAlertId = 2000;

  /// The daily repeating reminder older versions set. It fired whether or not
  /// anything was left to mark, so an upgrade has to cancel it.
  static const int _retiredEveningReminderId = 10;

  /// Today and the thirty days after it: how long these keep coming without
  /// the app being opened. Ids go round one more than this, so yesterday's
  /// reminder has an id of its own to be cleared under.
  static const int eveningDays = 31;

  /// Ids 2000-2004 belonged to the one-alert-per-subject version, so an
  /// upgrade has to clear them too.
  static const int _retiredDangerAlerts = 5;

  /// Subjects the tray has already warned about. Stored rather than held in
  /// memory: a restart is not news, and this runs on every data change.
  static const String _warnedKey = 'ut.warnedSubjects';

  /// Stacks leftover reminders under one heading when classes run back to back.
  static const String _classGroupKey = 'zeolite.class_reminders';

  /// Android caps pending alarms (500 on most OEM builds). A week of classes
  /// is well inside that, and we refresh on every data change anyway.
  static const int _maxClassReminders = 60;
  static const int _maxClassEndReminders = 60;

  /// The accent the tray tints the icon and app name with.
  ///
  /// Fixed when the reminder is scheduled, and the tray follows the *system*
  /// theme, so neither palette can be picked with confidence — the midpoint
  /// of the two reads on a white tray and on a dark one.
  static final Color _trayAccent =
      AppPalette.light.lerp(AppPalette.dark, 0.5).accent;

  // The three channel ids keep their pre-Zeolite names for the same reason the
  // database file does — an id is how Android finds an existing channel, and a
  // new one would silently discard whatever sound and importance the user had
  // set. Only the titles below are user-visible, and those never named the app.
  static const AndroidNotificationChannel _classChannel =
      AndroidNotificationChannel(
    'attend_it_classes',
    'Class reminders',
    description: 'Reminds you before a class and when it ends.',
    importance: Importance.high,
  );

  static const AndroidNotificationChannel _reminderChannel =
      AndroidNotificationChannel(
    'attend_it_reminders',
    'Attendance reminders',
    description: 'Evening nudge to mark classes you have not marked yet.',
    importance: Importance.defaultImportance,
  );

  static const AndroidNotificationChannel _alertChannel =
      AndroidNotificationChannel(
    'attend_it_alerts',
    'Attendance alerts',
    description: 'Warns you when a subject drops below your target.',
    importance: Importance.high,
  );

  /// Sets up timezone data and notification channels. Safe to call twice.
  Future<void> init({
    DidReceiveNotificationResponseCallback? backgroundAction,
  }) async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      final tz.Location? local = _resolveLocalLocation();
      if (local != null) tz.setLocalLocation(local);
    } catch (error, stack) {
      // A missing or unrecognised zone must never stop the app from starting;
      // scheduling simply falls back to whatever tz.local resolved to.
      debugPrint('Zeolite: timezone init failed: $error\n$stack');
    }

    const AndroidInitializationSettings android =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings settings =
        InitializationSettings(android: android);

    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          tappedPayload.value = response.payload;
        },
        onDidReceiveBackgroundNotificationResponse: backgroundAction,
      );

      // A tap that launched the app from cold does not reach the callback
      // above, so it has to be collected separately.
      final NotificationAppLaunchDetails? launch =
          await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        tappedPayload.value = launch!.notificationResponse?.payload;
      }

      final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(_classChannel);
        await androidPlugin.createNotificationChannel(_reminderChannel);
        await androidPlugin.createNotificationChannel(_alertChannel);
      }
      _ready = true;
    } catch (error, stack) {
      debugPrint('Zeolite: notification init failed: $error\n$stack');
    }
  }

  /// Works out which IANA zone the device is in, without a platform plugin.
  ///
  /// Dart already knows the correct local UTC offset and abbreviation; we just
  /// need the matching entry from the bundled tz database so that
  /// [tz.TZDateTime] can be constructed. Every candidate zone is evaluated at
  /// the current instant and the one agreeing on both offset and abbreviation
  /// wins, falling back to an offset-only match.
  ///
  /// Doing it this way avoids a plugin that applies the Kotlin Gradle Plugin,
  /// which Flutter is in the process of disallowing.
  tz.Location? _resolveLocalLocation() {
    final DateTime now = DateTime.now();
    final Duration offset = now.timeZoneOffset;
    final String abbreviation = now.timeZoneName;

    tz.Location? offsetOnlyMatch;
    for (final tz.Location location in tz.timeZoneDatabase.locations.values) {
      final tz.TZDateTime candidate = tz.TZDateTime.from(now, location);
      if (candidate.timeZoneOffset != offset) continue;
      if (candidate.timeZoneName == abbreviation) return location;
      offsetOnlyMatch ??= location;
    }
    return offsetOnlyMatch;
  }

  /// Asks for the Android 13+ POST_NOTIFICATIONS permission. Exact alarms are
  /// requested separately and are optional — we degrade to inexact scheduling.
  Future<bool> requestPermissions() async {
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return false;
    final bool granted =
        await androidPlugin.requestNotificationsPermission() ?? false;
    if (granted) {
      // Best effort: without this, reminders may fire a few minutes late.
      await androidPlugin.requestExactAlarmsPermission();
    }
    return granted;
  }

  /// Whether reminders can be scheduled to the minute. Only Android 12+ can
  /// answer no; below that exact alarms need no permission.
  Future<bool> canScheduleExactly() async {
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await androidPlugin?.canScheduleExactNotifications() ?? false;
  }

  /// Opens the system screen that grants exact alarms. There is no in-app
  /// dialog for this one.
  Future<void> requestExactAlarms() async {
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestExactAlarmsPermission();
  }

  Future<bool> areNotificationsEnabled() async {
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    return await androidPlugin?.areNotificationsEnabled() ?? false;
  }

  static const MethodChannel _settingsChannel =
      MethodChannel('zeolite/notification_settings');

  static final Map<String, TrayChannel> _channels = <String, TrayChannel>{
    _classChannel.id: TrayChannel.classes,
    _reminderChannel.id: TrayChannel.reminders,
    _alertChannel.id: TrayChannel.alerts,
  };

  /// Reads the answer back from Android. A channel the app has not created yet
  /// is not blocked, and a platform that cannot say is taken as open.
  Future<TrayAccess> trayAccess() async {
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return TrayAccess.open;
    try {
      return trayAccessFrom(
        appAllowed: await androidPlugin.areNotificationsEnabled(),
        channels: await androidPlugin.getNotificationChannels(),
      );
    } catch (error) {
      debugPrint('Zeolite: could not read notification access: $error');
      return TrayAccess.open;
    }
  }

  @visibleForTesting
  static TrayAccess trayAccessFrom({
    required bool? appAllowed,
    required List<AndroidNotificationChannel>? channels,
  }) {
    return TrayAccess(
      appAllowed: appAllowed ?? true,
      blocked: <TrayChannel>{
        for (final AndroidNotificationChannel c in channels ?? const [])
          if (c.importance == Importance.none && _channels[c.id] != null)
            _channels[c.id]!,
      },
    );
  }

  /// Asks again when Android still allows it to, and otherwise opens the
  /// screen that decides: once the prompt has been refused, asking is silent.
  Future<void> allowNotifications() async {
    if (await requestPermissions()) return;
    await openSettings();
  }

  /// Opens the system notification screen for the app, or for one channel.
  Future<void> openSettings({TrayChannel? channel}) async {
    final String? id = channel == null
        ? null
        : _channels.entries
            .firstWhere((MapEntry<String, TrayChannel> e) => e.value == channel)
            .key;
    try {
      await _settingsChannel.invokeMethod<void>(
        'open',
        <String, Object?>{'channel': id},
      );
    } on PlatformException catch (error) {
      debugPrint('Zeolite: could not open notification settings: $error');
    } on MissingPluginException {
      return;
    }
  }

  Future<AndroidScheduleMode> _scheduleMode() async {
    return await canScheduleExactly()
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
  }

  /// Rebuilds every scheduled notification from the current timetable and
  /// settings. Called whenever classes, marks or settings change.
  Future<void> rescheduleAll({
    required AppSettings settings,
    required List<ClassSession> upcoming,
    required List<ClassSession> eveningSessions,
    required OverallStats stats,
  }) async {
    if (!_ready) await init();
    if (!_ready) return;

    await _cancelRange(_classReminderBase, _maxClassReminders);
    await _cancelRange(_classEndReminderBase, _maxClassEndReminders);
    await _plugin.cancel(id: _retiredEveningReminderId);

    // The master switch short-circuits everything. The cancellations above have
    // already run, so flipping it off clears the tray rather than leaving
    // previously scheduled alarms behind.
    if (!settings.notificationsEnabled) {
      await _cancelRange(_eveningReminderBase, eveningDays + 1);
      await _clearDangerAlerts();
      return;
    }

    final AndroidScheduleMode mode = await _scheduleMode();

    if (settings.notifyBeforeClass) {
      await _scheduleClassReminders(settings, upcoming, stats, mode);
    }
    if (settings.notifyAtClassEnd) {
      await _scheduleClassEndReminders(settings, upcoming, stats, mode);
    }
    if (settings.notifyEveningReminder) {
      await _updateEveningReminders(settings, eveningSessions, mode);
    } else {
      await _cancelRange(_eveningReminderBase, eveningDays + 1);
    }
    if (settings.notifyAttendanceDanger) {
      await _updateDangerAlerts(stats);
    } else {
      // Switching it off and on again is asking for the warning, so the record
      // goes with the alert and the next slip counts as the first.
      await _clearDangerAlerts();
    }
  }

  /// The subjects a danger alert would be raised for. Exposed so the in-app
  /// alert shows exactly the same set as the system notification would, rather
  /// than reimplementing the rule and drifting from it.
  static List<SubjectStats> subjectsInDanger(OverallStats stats) =>
      <SubjectStats>[...stats.atRisk, ...stats.tight];

  /// What the tray should do about [inDanger], given what it has already
  /// warned about.
  ///
  /// This runs on every mark, edit, settings change and sync, so raising the
  /// warning whenever anything sat below the line meant raising the same one
  /// all day. Only a subject that has newly fallen is news; one that recovers
  /// is forgotten, so a later slip warns afresh. The rule the in-app alert
  /// already follows in `AnnouncedAlertsController`.
  static DangerDecision decideDangerAlert({
    required Set<int> inDanger,
    required Set<int> warned,
  }) {
    if (inDanger.isEmpty) {
      return const DangerDecision(DangerAlert.clear, <int>{});
    }
    if (inDanger.difference(warned).isEmpty) {
      return DangerDecision(DangerAlert.leave, warned.intersection(inDanger));
    }
    return DangerDecision(DangerAlert.raise, inDanger);
  }

  Future<Set<int>> _warnedSubjects() async {
    final List<String>? stored =
        await SharedPreferencesAsync().getStringList(_warnedKey);
    return <int>{
      for (final String id in stored ?? const <String>[])
        if (int.tryParse(id) != null) int.parse(id),
    };
  }

  Future<void> _rememberWarned(Set<int> warned) =>
      SharedPreferencesAsync().setStringList(
        _warnedKey,
        <String>[for (final int id in warned) id.toString()],
      );

  Future<void> _clearDangerAlerts() async {
    await _cancelRange(_dangerAlertId, _retiredDangerAlerts);
    await _rememberWarned(<int>{});
  }

  Future<void> _cancelRange(int base, int count) async {
    for (int i = 0; i < count; i++) {
      await _plugin.cancel(id: base + i);
    }
  }

  /// Where a class reminder is going: when it starts, where, and who teaches
  /// it, with whatever is missing simply left out.
  ///
  /// "Starts at" is gone because the title already says "in 15 min" — the two
  /// together were saying the same thing twice.
  static String reminderDetailLine(
    ClassSession session, {
    required bool use24Hour,
  }) {
    final String? room = session.room;
    final String? teacher = session.subject.teacher;
    return <String>[
      Clock.format(session.startMinutes, use24Hour: use24Hour),
      if (room != null && room.isNotEmpty) room,
      if (teacher != null && teacher.isNotEmpty) teacher,
    ].join(' · ');
  }

  /// The forward-looking sentence under the details, or null when there is
  /// nothing useful to say yet.
  ///
  /// Reuses [SubjectStats.headline] rather than composing a second phrasing of
  /// the same number, so the tray, the Today card and the Stats screen cannot
  /// drift apart. A subject with no marks is skipped: "No classes marked yet"
  /// on a reminder for the class you are about to attend is noise.
  static String? reminderStandingLine(SubjectStats? subjectStats) {
    if (subjectStats == null || !subjectStats.hasData) return null;
    return subjectStats.headline;
  }

  /// The class-end title: the subject, led by how it currently stands.
  ///
  /// The percentage goes first because it is the reason to read the
  /// notification rather than swipe it away.
  ///
  /// Plain text: Android 12 strips size and colour spans from notification
  /// text, so setting the figure apart is not available to us.
  ///
  /// A subject with nothing marked gets its name alone, the rule
  /// [reminderStandingLine] already follows.
  static String classEndTitle(
    ClassSession session,
    SubjectStats? subjectStats,
  ) {
    final String name = session.subject.name;
    if (subjectStats == null || !subjectStats.hasData) return name;
    return '${subjectStats.percent.toStringAsFixed(0)}% $name';
  }

  Future<void> _scheduleClassReminders(
    AppSettings settings,
    List<ClassSession> upcoming,
    OverallStats stats,
    AndroidScheduleMode mode,
  ) async {
    final Map<int, SubjectStats> statsBySubject = <int, SubjectStats>{
      for (final SubjectStats s in stats.subjects)
        if (s.subject.id != null) s.subject.id!: s,
    };

    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    int scheduled = 0;

    for (final ClassSession session in upcoming) {
      if (scheduled >= _maxClassReminders) break;

      final DateTime fireAt = session.startDateTime
          .subtract(Duration(minutes: settings.notifyLeadMinutes));
      final tz.TZDateTime tzFireAt = tz.TZDateTime.from(fireAt, tz.local);
      if (!tzFireAt.isAfter(now)) continue;

      final String detail = reminderDetailLine(
        session,
        use24Hour: settings.use24HourTime,
      );
      final String? standing =
          reminderStandingLine(statsBySubject[session.subject.id]);
      final String body = standing == null ? detail : '$detail\n$standing';

      // Built per notification rather than once outside the loop, because the
      // big-text style carries the text itself. It is what keeps the second
      // line out of the collapsed tray entry and visible on expand, so the
      // reminder gains a line without taking more room.
      final NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _classChannel.id,
          _classChannel.name,
          channelDescription: _classChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          groupKey: _classGroupKey,
          styleInformation: BigTextStyleInformation(body),
        ),
      );

      try {
        await _plugin.zonedSchedule(
          id: _classReminderBase + scheduled,
          title: '${session.subject.name} in ${settings.notifyLeadMinutes} min',
          body: body,
          scheduledDate: tzFireAt,
          notificationDetails: details,
          androidScheduleMode: mode,
          payload: 'class:${session.key}',
        );
        scheduled++;
      } catch (error) {
        debugPrint('Zeolite: could not schedule class reminder: $error');
      }
    }
  }

  Future<void> _scheduleClassEndReminders(
    AppSettings settings,
    List<ClassSession> upcoming,
    OverallStats stats,
    AndroidScheduleMode mode,
  ) async {
    final Map<int, SubjectStats> statsBySubject = <int, SubjectStats>{
      for (final SubjectStats s in stats.subjects)
        if (s.subject.id != null) s.subject.id!: s,
    };

    // Android drops action icons from the standard template on 7 and above,
    // so the glyph has to be the label.
    const List<AndroidNotificationAction> actions = <AndroidNotificationAction>[
      AndroidNotificationAction('present', '✓'),
      AndroidNotificationAction('absent', '✕'),
      AndroidNotificationAction('cancelled', 'O'),
    ];

    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    int scheduled = 0;
    for (final ClassSession session in upcoming) {
      if (scheduled >= _maxClassEndReminders) break;
      if (session.isMarked) continue;

      final tz.TZDateTime fireAt =
          tz.TZDateTime.from(session.endDateTime, tz.local);
      if (!fireAt.isAfter(now)) continue;

      final SubjectStats? subjectStats = statsBySubject[session.subject.id];
      final String detail = reminderDetailLine(
        session,
        use24Hour: settings.use24HourTime,
      );
      final String? standing = reminderStandingLine(subjectStats);
      final String body = standing == null ? detail : '$detail\n$standing';

      // Per notification: the title carries this subject's standing, and the
      // style has to repeat it for the expanded form.
      final NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _classChannel.id,
          _classChannel.name,
          channelDescription: _classChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          groupKey: _classGroupKey,
          color: _trayAccent,
          // In the header rather than the title: it dates the notification
          // rather than describing the class.
          subText: 'Just ended',
          actions: actions,
          styleInformation: BigTextStyleInformation(
            body,
            contentTitle: classEndTitle(session, subjectStats),
          ),
        ),
      );

      try {
        await _plugin.zonedSchedule(
          id: _classEndReminderBase + scheduled,
          title: classEndTitle(session, subjectStats),
          body: body,
          scheduledDate: fireAt,
          notificationDetails: details,
          androidScheduleMode: mode,
          payload: 'class:${session.key}',
        );
        scheduled++;
      } catch (error) {
        debugPrint('Zeolite: could not schedule class-end reminder: $error');
      }
    }
  }

  /// How many classes each day's evening reminder would count, by day key.
  ///
  /// Only classes over by the time it fires: one still to come at 21:00 is
  /// not something the 20:00 reminder can ask you to mark. A day with nothing
  /// left is absent, which is what stops the reminder going off at all.
  static Map<int, int> eveningCounts(
    List<ClassSession> sessions, {
    required int reminderMinutes,
  }) {
    final Map<int, int> counts = <int, int>{};
    for (final ClassSession session in sessions) {
      if (session.isMarked || session.endMinutes > reminderMinutes) continue;
      final int key = Dates.keyOf(session.date);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  static String eveningBody(int count) =>
      count == 1 ? '1 class still unmarked' : '$count classes still unmarked';

  /// A reminder already in the tray stays, its count kept current, until the
  /// last class is marked. Cancelling it on every pass would clear the nudge
  /// for the classes still left.
  static EveningReminder decideEvening({
    required int count,
    required bool due,
    required bool shown,
  }) {
    if (count == 0) return EveningReminder.cancel;
    if (!due) return EveningReminder.schedule;
    return shown ? EveningReminder.refresh : EveningReminder.leave;
  }

  static int _eveningIdFor(DateTime day) {
    final int epochDay =
        DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch ~/
            Duration.millisecondsPerDay;
    return _eveningReminderBase + epochDay % (eveningDays + 1);
  }

  Future<void> _updateEveningReminders(
    AppSettings settings,
    List<ClassSession> sessions,
    AndroidScheduleMode mode,
  ) async {
    final Map<int, int> counts =
        eveningCounts(sessions, reminderMinutes: settings.eveningReminderMinutes);
    final Set<int> shown = <int>{
      for (final ActiveNotification n in await _activeNotifications())
        if (n.id != null) n.id!,
    };

    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    final DateTime today = DateTime(now.year, now.month, now.day);
    await _plugin.cancel(id: _eveningIdFor(Dates.addDays(today, -1)));

    for (int i = 0; i < eveningDays; i++) {
      final DateTime day = Dates.addDays(today, i);
      final int id = _eveningIdFor(day);
      final int count = counts[Dates.keyOf(day)] ?? 0;
      final tz.TZDateTime fireAt = tz.TZDateTime(
        tz.local,
        day.year,
        day.month,
        day.day,
        Clock.hourOf(settings.eveningReminderMinutes),
        Clock.minuteOf(settings.eveningReminderMinutes),
      );
      final EveningReminder action = decideEvening(
        count: count,
        due: !fireAt.isAfter(now),
        shown: shown.contains(id),
      );

      final NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _reminderChannel.id,
          _reminderChannel.name,
          channelDescription: _reminderChannel.description,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          // A refresh only changes the count; it should not sound again.
          onlyAlertOnce: true,
        ),
      );
      try {
        switch (action) {
          case EveningReminder.cancel:
            await _plugin.cancel(id: id);
          case EveningReminder.leave:
            break;
          case EveningReminder.schedule:
            await _plugin.zonedSchedule(
              id: id,
              title: 'Mark today\'s attendance',
              body: eveningBody(count),
              scheduledDate: fireAt,
              notificationDetails: details,
              androidScheduleMode: mode,
              payload: 'evening',
            );
          case EveningReminder.refresh:
            await _plugin.show(
              id: id,
              title: 'Mark today\'s attendance',
              body: eveningBody(count),
              notificationDetails: details,
              payload: 'evening',
            );
        }
      } catch (error) {
        debugPrint('Zeolite: could not schedule evening reminder: $error');
      }
    }
  }

  Future<List<ActiveNotification>> _activeNotifications() async {
    try {
      return await _plugin.getActiveNotifications();
    } catch (error) {
      debugPrint('Zeolite: could not read the tray: $error');
      return const <ActiveNotification>[];
    }
  }

  /// The wording used for one subject's warning, shared by the system
  /// notification and the in-app alert so both always say the same thing.
  ///
  /// One shape either side of the target — the on-target case used to get a
  /// sentence of its own — and rounded like every percentage elsewhere.
  static String dangerMessage(SubjectStats subjectStats) =>
      '${subjectStats.percent.toStringAsFixed(0)}% · ${subjectStats.headline}';

  /// Shared with the in-app dialog, so the two cannot word it differently.
  static String dangerTitle(int count) =>
      count == 1 ? 'Worth a look' : '$count subjects worth a look';

  /// For the tray, which has no typography to set the name off from the rest.
  static String dangerLine(SubjectStats subjectStats) =>
      '${subjectStats.subject.name} · ${dangerMessage(subjectStats)}';

  /// Raises the warning when a subject has newly fallen below its target or
  /// onto the edge — all of them in one notification, because four arriving
  /// at once otherwise read as four unrelated problems.
  Future<void> _updateDangerAlerts(OverallStats stats) async {
    final List<SubjectStats> danger = subjectsInDanger(stats);
    final DangerDecision decision = decideDangerAlert(
      inDanger: <int>{
        for (final SubjectStats s in danger)
          if (s.subject.id != null) s.subject.id!,
      },
      warned: await _warnedSubjects(),
    );

    switch (decision.action) {
      case DangerAlert.clear:
        return _clearDangerAlerts();
      // Left standing rather than cancelled and shown again, which is what
      // made every mark buzz.
      case DangerAlert.leave:
        return _rememberWarned(decision.warned);
      case DangerAlert.raise:
        break;
    }

    final List<String> lines = danger.map(dangerLine).toList();
    final String title = dangerTitle(danger.length);

    // Collapsed, one warning fits whole; several can only name their subjects.
    final bool single = danger.length == 1;
    final String body = single
        ? lines.first
        : danger.map((SubjectStats s) => s.subject.name).join(' · ');

    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        _alertChannel.id,
        _alertChannel.name,
        channelDescription: _alertChannel.description,
        importance: Importance.high,
        priority: Priority.high,
        // Inbox style clips every row to one line, which cut each subject
        // off mid-advice on a phone. Big text wraps.
        styleInformation: BigTextStyleInformation(
          lines.join('\n'),
          contentTitle: title,
        ),
      ),
    );

    try {
      await _plugin.show(
        id: _dangerAlertId,
        title: title,
        body: body,
        notificationDetails: details,
        payload: 'danger',
      );
      await _rememberWarned(decision.warned);
    } catch (error) {
      debugPrint('Zeolite: could not show attendance alert: $error');
    }
  }

  Future<void> cancelAll() => _plugin.cancelAll();
}
