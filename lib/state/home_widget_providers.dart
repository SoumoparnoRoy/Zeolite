import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../core/date_utils.dart';
import '../core/report_error.dart';
import '../data/models/attendance_status.dart';
import '../data/models/class_session.dart';
import '../data/settings/app_settings.dart';
import '../domain/attendance_stats.dart';
import '../domain/home_widget_payload.dart';
import '../domain/schedule_engine.dart';
import '../services/home_widget_service.dart';
import '../services/notification_service.dart';
import 'actions/action_core.dart';
import 'actions/attendance_actions.dart';
import 'app_providers.dart';

final homeWidgetServiceProvider = Provider<HomeWidgetService>(
  (ref) => const HomeWidgetService(),
);

/// Keeps the home-screen widgets in step with the database.
///
/// Watched rather than called, so every path that moves the timetable — a
/// mark, an import, a sync pull — pushes without having to remember to. The
/// week widget's picture is drawn by `weekWidgetImageProvider`, next to the
/// grid it draws.
final homeWidgetSyncProvider = Provider<void>((Ref ref) {
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
  final AppSettings? settings = ref.watch(settingsProvider).value;
  if (engine == null || settings == null) return;
  final OverallStats stats = ref.watch(statsProvider);
  final HomeWidgetService service = ref.watch(homeWidgetServiceProvider);
  final List<ClassSession> upcoming = HomeWidgetPayload.upcoming(engine);

  unawaited(
    service.push(
      today: HomeWidgetPayload.today(engine: engine, settings: settings),
      standing: HomeWidgetPayload.standing(
        upcoming: upcoming,
        stats: stats,
        settings: settings,
      ),
      subjects: HomeWidgetPayload.subjects(stats),
      theme: HomeWidgetPayload.theme(settings),
      classStarts: _startsOf(upcoming),
    ),
  );
});

/// Reloads the app when a widget mark landed while it was in the background.
///
/// The mark is written by a second isolate, so the running app's copy of the
/// timetable is simply wrong until something invalidates it — which is what
/// made a mark look like it had not been saved. The first check only records
/// where the stamp stands, since a launch reads the database fresh anyway.
final homeWidgetMarkWatcherProvider = Provider<void>((Ref ref) {
  String? seen;
  bool primed = false;

  // [announced] always reloads: on a cold start the write can land between
  // the launch's read and this first check.
  Future<void> check({bool announced = false}) async {
    try {
      final String? stamp = await HomeWidget.getWidgetData<String>(
        HomeWidgetService.markEpochKey,
      );
      if (stamp == null || (!announced && stamp == seen)) return;
      if (!primed && !announced) {
        primed = true;
        seen = stamp;
        return;
      }
      await ref.read(actionCoreProvider).reloadAfterWidgetMark();
      // Only once the reload has happened, so a failed one is tried again at
      // the next resume rather than skipped until another mark comes in.
      primed = true;
      seen = stamp;
    } catch (error, stack) {
      reportError(error, stack, where: 'widget mark reload');
    }
  }

  final AppLifecycleListener listener =
      AppLifecycleListener(onResume: () => unawaited(check()));
  ref.onDispose(listener.dispose);

  // A resume can land between two quick taps and reload a mark that is about
  // to change, so the writing isolate also says when it has written.
  final ReceivePort written = ReceivePort();
  IsolateNameServer.removePortNameMapping(_markWrittenPort);
  IsolateNameServer.registerPortWithName(written.sendPort, _markWrittenPort);
  written.listen((_) => unawaited(check(announced: true)));
  ref.onDispose(() {
    IsolateNameServer.removePortNameMapping(_markWrittenPort);
    written.close();
  });

  unawaited(check());
});

/// Process-wide, so the widget-tap isolate can reach the app's port.
const String _markWrittenPort = 'zeolite.widgetMarkWritten';

/// Does nothing with no app running; its launch reads the database fresh.
@visibleForTesting
void announceExternalMark() =>
    IsolateNameServer.lookupPortByName(_markWrittenPort)?.send(null);

/// A request to mark one occurrence from a surface outside the running app.
@immutable
class ExternalMarkRequest {
  const ExternalMarkRequest({
    required this.subjectId,
    required this.dateKey,
    required this.startMinutes,
    required this.status,
    this.drawnAt,
  });

  final int subjectId;
  final int dateKey;
  final int startMinutes;
  final AttendanceStatus status;

  /// Stamped by `WidgetMarkReceiver` when it drew this tap on the widget.
  final String? drawnAt;

  /// What the widget drew for this tap, to take back once it is saved.
  PendingTap get drawn =>
      (key: '$subjectId:$dateKey:$startMinutes', at: drawnAt);

  static ExternalMarkRequest? fromWidget(Uri? uri) {
    if (uri == null || uri.host != 'mark') return null;
    final Map<String, String> q = uri.queryParameters;
    return _from(
      subject: q['subject'],
      date: q['date'],
      start: q['start'],
      status: q['status'],
      drawnAt: q['drawn'],
    );
  }

  static ExternalMarkRequest? fromNotification(
    NotificationResponse response,
  ) {
    final List<String> parts = response.payload?.split(':') ?? <String>[];
    if (parts.length != 4 || parts.first != 'class') return null;
    return _from(
      subject: parts[1],
      date: parts[2],
      start: parts[3],
      status: response.actionId,
    );
  }

  static ExternalMarkRequest? _from({
    required String? subject,
    required String? date,
    required String? start,
    required String? status,
    String? drawnAt,
  }) {
    final int? subjectId = int.tryParse(subject ?? '');
    final int? dateKey = int.tryParse(date ?? '');
    final int? startMinutes = int.tryParse(start ?? '');
    final AttendanceStatus? parsedStatus = AttendanceStatus.fromName(status);
    if (subjectId == null ||
        dateKey == null ||
        startMinutes == null ||
        parsedStatus == null) {
      return null;
    }
    return ExternalMarkRequest(
      subjectId: subjectId,
      dateKey: dateKey,
      startMinutes: startMinutes,
      status: parsedStatus,
      drawnAt: drawnAt,
    );
  }
}

/// Wakes on a status tap in the Today widget, with no app on screen.
///
/// The URI is treated as a request, not as fact: it names an occurrence by its
/// natural key and nothing more, and the session is looked up fresh here. A
/// widget can sit on a home screen for days after the class it names was
/// deleted, and a mark written from a stale label would be invisible and
/// wrong.
@pragma('vm:entry-point')
Future<void> handleWidgetTap(Uri? uri) async {
  final ExternalMarkRequest? request = ExternalMarkRequest.fromWidget(uri);
  if (request == null) return;
  await _handleExternalMark(request, source: 'Widget', toggles: true);
}

/// Handles an action without opening the app, including from a killed process.
@pragma('vm:entry-point')
Future<void> handleNotificationAction(NotificationResponse response) async {
  final ExternalMarkRequest? request =
      ExternalMarkRequest.fromNotification(response);
  if (request == null) return;
  await _handleExternalMark(request, source: 'Notification', toggles: false);
}

/// Taps that land together are handled one after another, each reading the
/// class as the last one left it. The plugin hands queued taps to this
/// isolate back to back, and run side by side two quick taps on one button
/// both read the old status: the second, which should have cleared the mark,
/// was lost.
@visibleForTesting
Future<T> oneAtATime<T>(Future<T> Function() work) {
  final Future<T> next = _lastTap.then((_) => work());
  _lastTap = next.then((_) {}, onError: (Object _) {});
  return next;
}

Future<void> _lastTap = Future<void>.value();

/// Only the marks wait for one another. Rescheduling the reminders takes
/// seconds, and a second tap held behind it left the app, which reloads at
/// every write, on the first tap's status all that time. The reminders keep
/// their own order, so the last run reads the last mark.
@visibleForTesting
Future<void> markThenRemind({
  required Future<bool> Function() mark,
  required Future<void> Function() remind,
}) async {
  Future<void>? reminders;
  await oneAtATime(() async {
    if (!await mark()) return;
    // Queued inside the mark's turn: from outside it, a later tap could get
    // its reminders in first.
    final Future<void> next = _lastReminders.then((_) => remind());
    _lastReminders = next.then((_) {}, onError: (Object _) {});
    reminders = next;
  });
  await reminders;
}

Future<void> _lastReminders = Future<void>.value();

Future<void> _handleExternalMark(
  ExternalMarkRequest request, {
  required String source,
  required bool toggles,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final ProviderContainer container = ProviderContainer();
  try {
    await markThenRemind(
      mark: () async {
        final bool marked = await applyExternalMark(
          container,
          request,
          toggles: toggles,
          redraw: () => _pushFromContainer(container, settles: request.drawn),
        );
        if (!marked) return false;
        await HomeWidget.saveWidgetData<String>(
          HomeWidgetService.markEpochKey,
          DateTime.now().microsecondsSinceEpoch.toString(),
        );
        announceExternalMark();
        return true;
      },
      // Reminders carry the standing, so a mark made here has to reschedule
      // them the same way one made in the app does. After the redraw, because
      // on a cold start this is most of the wait. Best-effort: the service
      // logs and swallows its own failures.
      remind: () async {
        await NotificationService.instance.init(
          backgroundAction: handleNotificationAction,
        );
        await container.read(actionCoreProvider).refreshNotifications();
      },
    );
  } catch (error, stack) {
    reportError(error, stack, where: '$source mark');
  } finally {
    container.dispose();
  }
}

/// Saves [request] and then calls [redraw], which runs whatever happened
/// first — a class that has gone, a refused tap, a database that would not
/// open. The Today widget may already be showing the tap as made (the native
/// receiver draws it before Dart wakes), and only a redraw puts it right.
/// True when a mark was written; the reminders are left to the caller.
@visibleForTesting
Future<bool> applyExternalMark(
  ProviderContainer container,
  ExternalMarkRequest request, {
  required bool toggles,
  required Future<void> Function() redraw,
}) async {
  container.read(actionCoreProvider).holdNotifications = true;
  try {
    // Both, and awaited: the engine and the payload read settings, and an
    // isolate that has only asked for them still holds an unresolved future —
    // which silently skipped the redraw and left the widget on the old status.
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);
    final ScheduleEngine? engine = container.read(scheduleEngineProvider);
    if (engine == null) return false;

    ClassSession? session;
    for (final ClassSession candidate
        in engine.sessionsOn(Dates.fromKey(request.dateKey))) {
      if (candidate.subject.id == request.subjectId &&
          candidate.startMinutes == request.startMinutes) {
        session = candidate;
        break;
      }
    }
    // A widget tap is a gesture and behaves like the Today screen: tapping the
    // status a class already has clears it. A notification action is not —
    // the same action can arrive twice, and the second must not undo the first.
    if (session == null || (!toggles && session.status == request.status)) {
      return false;
    }
    await container
        .read(attendanceActionsProvider)
        .mark(session, request.status);
    return true;
  } finally {
    try {
      await redraw();
    } catch (error, stack) {
      // Never in place of whatever is already on its way out of the try.
      reportError(error, stack, where: 'widget redraw after a mark');
    }
  }
}

/// The JSON half of [homeWidgetSyncProvider], for the isolate that has no view
/// to draw the week image into. With nothing to build a payload from — the
/// database or settings failed to load — it only takes back what the widget
/// drew for the tap, so the last payload shows instead.
Future<void> _pushFromContainer(
  ProviderContainer container, {
  required PendingTap settles,
}) async {
  const HomeWidgetService service = HomeWidgetService();
  final _WidgetPayload? payload;
  try {
    payload = _payloadFrom(container);
  } catch (error, stack) {
    reportError(error, stack, where: 'widget payload after a mark');
    await service.settleOnly(settles);
    return;
  }
  if (payload == null) {
    await service.settleOnly(settles);
    return;
  }
  await service.push(
    today: payload.today,
    standing: payload.standing,
    subjects: payload.subjects,
    theme: payload.theme,
    classStarts: payload.classStarts,
    settles: settles,
  );
}

List<DateTime> _startsOf(List<ClassSession> upcoming) => <DateTime>[
      for (final ClassSession session in upcoming) session.startDateTime,
    ];

typedef _WidgetPayload = ({
  Map<String, Object?> today,
  Map<String, Object?> standing,
  Map<String, Object?> subjects,
  Map<String, Object?>? theme,
  List<DateTime> classStarts,
});

_WidgetPayload? _payloadFrom(ProviderContainer container) {
  final ScheduleEngine? engine = container.read(scheduleEngineProvider);
  final AppSettings? settings = container.read(settingsProvider).value;
  if (engine == null || settings == null) return null;
  final OverallStats stats = container.read(statsProvider);
  final List<ClassSession> upcoming = HomeWidgetPayload.upcoming(engine);
  return (
    today: HomeWidgetPayload.today(engine: engine, settings: settings),
    standing: HomeWidgetPayload.standing(
      upcoming: upcoming,
      stats: stats,
      settings: settings,
    ),
    classStarts: _startsOf(upcoming),
    subjects: HomeWidgetPayload.subjects(stats),
    // Android tells a background engine nothing about dark mode, so System
    // would always read as light here and turn the widget white on every
    // widget mark. The colours the app last wrote in the foreground stand.
    theme: settings.themeMode == AppThemeMode.system
        ? null
        : HomeWidgetPayload.theme(settings),
  );
}

/// Registers the tap handler. Called once at launch: the handles it stores are
/// what Android uses to spin up an isolate later, so a device that never opens
/// the app again still marks correctly.
Future<void> registerHomeWidgetCallbacks() async {
  try {
    await HomeWidget.registerInteractivityCallback(handleWidgetTap);
  } catch (error, stack) {
    reportError(error, stack, where: 'home widget callback registration');
  }
}
