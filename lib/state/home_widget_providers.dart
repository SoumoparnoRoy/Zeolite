import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../core/date_utils.dart';
import '../data/models/attendance_status.dart';
import '../data/models/class_session.dart';
import '../data/settings/app_settings.dart';
import '../domain/attendance_stats.dart';
import '../domain/home_widget_payload.dart';
import '../domain/schedule_engine.dart';
import '../services/home_widget_service.dart';
import '../services/notification_service.dart';
import 'providers.dart';

final homeWidgetServiceProvider = Provider<HomeWidgetService>(
  (ref) => const HomeWidgetService(),
);

/// Keeps the home-screen widgets in step with the database.
///
/// Watched rather than called, so every path that moves the timetable — a
/// mark, an import, a sync pull — pushes without having to remember to. The
/// week image is only redrawn when the app is in the foreground, which is the
/// one thing this cannot do from anywhere else.
final homeWidgetSyncProvider = Provider<void>((Ref ref) {
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
  final AppSettings? settings = ref.watch(settingsProvider).value;
  if (engine == null || settings == null) return;
  final OverallStats stats = ref.watch(statsProvider);
  final HomeWidgetService service = ref.watch(homeWidgetServiceProvider);

  unawaited(() async {
    await service.push(
      today: HomeWidgetPayload.today(engine: engine, settings: settings),
      week: HomeWidgetPayload.week(engine: engine),
      standing: HomeWidgetPayload.standing(
        engine: engine,
        stats: stats,
        settings: settings,
      ),
      subjects: HomeWidgetPayload.subjects(stats),
      theme: HomeWidgetPayload.theme(settings),
    );
    await service.renderWeek(
      container: ref.container,
      settings: settings,
      // Only until the widget has drawn once and reported its own cell.
      fallbackSize: const Size(420, 215),
    );
  }());
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

  Future<void> check() async {
    final String? stamp = await HomeWidget.getWidgetData<String>(
      HomeWidgetService.markEpochKey,
    );
    if (stamp == null || stamp == seen) return;
    seen = stamp;
    if (!primed) {
      primed = true;
      return;
    }
    await ref.read(actionsProvider).reloadAfterWidgetMark();
  }

  final AppLifecycleListener listener =
      AppLifecycleListener(onResume: () => unawaited(check()));
  ref.onDispose(listener.dispose);
  unawaited(check());
});

/// A request to mark one occurrence from a surface outside the running app.
@immutable
class ExternalMarkRequest {
  const ExternalMarkRequest({
    required this.subjectId,
    required this.dateKey,
    required this.startMinutes,
    required this.status,
  });

  final int subjectId;
  final int dateKey;
  final int startMinutes;
  final AttendanceStatus status;

  static ExternalMarkRequest? fromWidget(Uri? uri) {
    if (uri == null || uri.host != 'mark') return null;
    final Map<String, String> q = uri.queryParameters;
    return _from(
      subject: q['subject'],
      date: q['date'],
      start: q['start'],
      status: q['status'],
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
  await _handleExternalMark(request, source: 'Widget');
}

/// Handles an action without opening the app, including from a killed process.
@pragma('vm:entry-point')
Future<void> handleNotificationAction(NotificationResponse response) async {
  final ExternalMarkRequest? request =
      ExternalMarkRequest.fromNotification(response);
  if (request == null) return;
  await _handleExternalMark(request, source: 'Notification');
}

Future<void> _handleExternalMark(
  ExternalMarkRequest request, {
  required String source,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final ProviderContainer container = ProviderContainer();
  try {
    // Reminders carry the standing, so a mark made here has to reschedule them
    // the same way one made in the app does. Best-effort: the service logs and
    // swallows its own failures.
    await NotificationService.instance.init(
      backgroundAction: handleNotificationAction,
    );
    // Both, and awaited: the engine and the payload read settings, and an
    // isolate that has only asked for them still holds an unresolved future —
    // which silently skipped the redraw and left the widget on the old status.
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);
    final ScheduleEngine? engine = container.read(scheduleEngineProvider);
    if (engine == null) return;

    final DateTime date = Dates.fromKey(request.dateKey);
    ClassSession? session;
    for (final ClassSession candidate in engine.sessionsOn(date)) {
      if (candidate.subject.id == request.subjectId &&
          candidate.startMinutes == request.startMinutes) {
        session = candidate;
        break;
      }
    }
    if (session == null) return;

    // An action means "set", not "toggle". A duplicate delivery must not
    // clear a mark that already has the requested value.
    if (session.status != request.status) {
      await container.read(actionsProvider).mark(session, request.status);
    }
    await _pushFromContainer(container);
    await HomeWidget.saveWidgetData<String>(
      HomeWidgetService.markEpochKey,
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
  } catch (error) {
    debugPrint('$source mark failed: $error');
  } finally {
    container.dispose();
  }
}

/// The JSON half of [homeWidgetSyncProvider], for the isolate that has no view
/// to draw the week image into.
Future<void> _pushFromContainer(ProviderContainer container) async {
  final ScheduleEngine? engine = container.read(scheduleEngineProvider);
  final AppSettings? settings = container.read(settingsProvider).value;
  if (engine == null || settings == null) return;
  await const HomeWidgetService().push(
    today: HomeWidgetPayload.today(engine: engine, settings: settings),
    week: HomeWidgetPayload.week(engine: engine),
    standing: HomeWidgetPayload.standing(
      engine: engine,
      stats: container.read(statsProvider),
      settings: settings,
    ),
    subjects: HomeWidgetPayload.subjects(container.read(statsProvider)),
    theme: HomeWidgetPayload.theme(settings),
  );
}

/// Registers the tap handler. Called once at launch: the handles it stores are
/// what Android uses to spin up an isolate later, so a device that never opens
/// the app again still marks correctly.
Future<void> registerHomeWidgetCallbacks() async {
  try {
    await HomeWidget.registerInteractivityCallback(handleWidgetTap);
  } catch (error) {
    debugPrint('Home widget callback not registered: $error');
  }
}
