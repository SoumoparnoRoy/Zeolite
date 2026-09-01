import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/date_utils.dart';
import '../data/models/class_session.dart';
import '../data/settings/app_settings.dart';
import '../domain/attendance_stats.dart';

/// All local notifications: class reminders, the evening "mark your
/// attendance" nudge, and attendance danger alerts.
///
/// Everything is scheduled on-device — no server, no push tokens. Android only
/// keeps a limited number of pending alarms, so class reminders are scheduled
/// as a rolling window (see [_maxClassReminders]) and refreshed whenever the
/// timetable changes.
class NotificationService {
  NotificationService._();

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
  static const int _eveningReminderId = 10;
  static const int _dangerAlertId = 2000;

  /// Ids 2000-2004 belonged to the one-alert-per-subject version, so an
  /// upgrade has to clear them too.
  static const int _retiredDangerAlerts = 5;

  /// Stacks leftover reminders under one heading when classes run back to back.
  static const String _classGroupKey = 'zeolite.class_reminders';

  /// Android caps pending alarms (500 on most OEM builds). A week of classes
  /// is well inside that, and we refresh on every data change anyway.
  static const int _maxClassReminders = 60;

  // The three channel ids keep their pre-Zeolite names for the same reason the
  // database file does — an id is how Android finds an existing channel, and a
  // new one would silently discard whatever sound and importance the user had
  // set. Only the titles below are user-visible, and those never named the app.
  static const AndroidNotificationChannel _classChannel =
      AndroidNotificationChannel(
    'attend_it_classes',
    'Class reminders',
    description: 'Reminds you shortly before a class starts.',
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
  Future<void> init() async {
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
    required OverallStats stats,
  }) async {
    if (!_ready) await init();
    if (!_ready) return;

    await _cancelRange(_classReminderBase, _maxClassReminders);
    await _plugin.cancel(id: _eveningReminderId);
    await _cancelRange(_dangerAlertId, _retiredDangerAlerts);

    // The master switch short-circuits everything. The cancellations above have
    // already run, so flipping it off clears the tray rather than leaving
    // previously scheduled alarms behind.
    if (!settings.notificationsEnabled) return;

    final AndroidScheduleMode mode = await _scheduleMode();

    if (settings.notifyBeforeClass) {
      await _scheduleClassReminders(settings, upcoming, stats, mode);
    }
    if (settings.notifyEveningReminder) {
      await _scheduleEveningReminder(settings, mode);
    }
    if (settings.notifyAttendanceDanger) {
      await _showDangerAlerts(stats);
    }
  }

  /// The subjects a danger alert would be raised for. Exposed so the in-app
  /// alert shows exactly the same set as the system notification would, rather
  /// than reimplementing the rule and drifting from it.
  static List<SubjectStats> subjectsInDanger(OverallStats stats) =>
      <SubjectStats>[...stats.atRisk, ...stats.tight];

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
      final String body =
          standing == null ? detail : '$detail\n$standing';

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

  Future<void> _scheduleEveningReminder(
    AppSettings settings,
    AndroidScheduleMode mode,
  ) async {
    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        _reminderChannel.id,
        _reminderChannel.name,
        channelDescription: _reminderChannel.description,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );

    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime fireAt = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      Clock.hourOf(settings.eveningReminderMinutes),
      Clock.minuteOf(settings.eveningReminderMinutes),
    );
    if (!fireAt.isAfter(now)) {
      fireAt = fireAt.add(const Duration(days: 1));
    }

    try {
      await _plugin.zonedSchedule(
        id: _eveningReminderId,
        title: 'Mark today\'s attendance',
        body: 'Tap to update Zeolite before you forget.',
        scheduledDate: fireAt,
        notificationDetails: details,
        androidScheduleMode: mode,
        // Repeats at the same wall-clock time every day.
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'evening',
      );
    } catch (error) {
      debugPrint('Zeolite: could not schedule evening reminder: $error');
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

  /// Fires immediately for any subject below its target or sitting on the
  /// edge — all of them in one notification, because four arriving at once
  /// otherwise read as four unrelated problems. Android truncates the inbox
  /// lines, so the name and the percentage lead.
  Future<void> _showDangerAlerts(OverallStats stats) async {
    final List<SubjectStats> danger = subjectsInDanger(stats);
    if (danger.isEmpty) return;

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
        styleInformation: single
            ? BigTextStyleInformation(lines.first)
            : InboxStyleInformation(lines, contentTitle: title),
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
    } catch (error) {
      debugPrint('Zeolite: could not show attendance alert: $error');
    }
  }

  Future<void> cancelAll() => _plugin.cancelAll();
}
