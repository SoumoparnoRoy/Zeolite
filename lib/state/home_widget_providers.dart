import 'dart:async';

import 'package:flutter/widgets.dart';
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

/// Wakes on a Present/Absent tap in the Today widget, with no app on screen.
///
/// The URI is treated as a request, not as fact: it names an occurrence by its
/// natural key and nothing more, and the session is looked up fresh here. A
/// widget can sit on a home screen for days after the class it names was
/// deleted, and a mark written from a stale label would be invisible and
/// wrong.
@pragma('vm:entry-point')
Future<void> handleWidgetTap(Uri? uri) async {
  if (uri == null || uri.host != 'mark') return;
  final Map<String, String> q = uri.queryParameters;
  final int? subjectId = int.tryParse(q['subject'] ?? '');
  final int? dateKey = int.tryParse(q['date'] ?? '');
  final int? startMinutes = int.tryParse(q['start'] ?? '');
  final AttendanceStatus? status = AttendanceStatus.fromName(q['status']);
  if (subjectId == null ||
      dateKey == null ||
      startMinutes == null ||
      status == null) {
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  final ProviderContainer container = ProviderContainer();
  try {
    // Reminders carry the standing, so a mark made here has to reschedule them
    // the same way one made in the app does. Best-effort: the service logs and
    // swallows its own failures.
    await NotificationService.instance.init();
    // Both, and awaited: the engine and the payload read settings, and an
    // isolate that has only asked for them still holds an unresolved future —
    // which silently skipped the redraw and left the widget on the old status.
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);
    final ScheduleEngine? engine = container.read(scheduleEngineProvider);
    if (engine == null) return;

    final DateTime date = Dates.fromKey(dateKey);
    ClassSession? session;
    for (final ClassSession candidate in engine.sessionsOn(date)) {
      if (candidate.subject.id == subjectId &&
          candidate.startMinutes == startMinutes) {
        session = candidate;
        break;
      }
    }
    if (session == null) return;

    await container.read(actionsProvider).mark(session, status);
    await _pushFromContainer(container);
    await HomeWidget.saveWidgetData<String>(
      HomeWidgetService.markEpochKey,
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
  } catch (error) {
    debugPrint('Widget mark failed: $error');
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
