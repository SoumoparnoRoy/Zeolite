import 'package:firebase_analytics/firebase_analytics.dart';

/// Everything the app reports about itself, named once.
///
/// Typed methods rather than event strings at the call sites: the privacy
/// policy states what is collected, and a string literal in a widget is how
/// that stops being true. Nothing here takes anything somebody typed.
abstract class Analytics {
  /// [name] is a screen, not a route path: no ids, since a route carrying a
  /// subject id would put one in the export.
  Future<void> screen(String name);

  /// That a class was marked, and nothing about how. The present/absent split
  /// would be attendance data, which the privacy policy promises never leaves
  /// the device, and it answers no question worth breaking that for.
  Future<void> attendanceMarked();

  /// [target] is `account` or `notion`, [outcome] a [SyncRunOutcome] name.
  Future<void> syncRan({required String target, required String outcome});

  Future<void> notionConnected();

  /// [source] is `paste`, `csv`, `totals` or `notion`.
  Future<void> timetableImported(String source);

  Future<void> backupExported();

  Future<void> backupRestored();

  Future<void> undoUsed();
}

class FirebaseAnalyticsService implements Analytics {
  FirebaseAnalyticsService(this._analytics);

  final FirebaseAnalytics _analytics;

  @override
  Future<void> screen(String name) =>
      _analytics.logScreenView(screenName: name);

  @override
  Future<void> attendanceMarked() => _log('attendance_marked');

  @override
  Future<void> syncRan({required String target, required String outcome}) =>
      _log(
        'sync_ran',
        <String, Object>{'target': target, 'outcome': outcome},
      );

  @override
  Future<void> notionConnected() => _log('notion_connected');

  @override
  Future<void> timetableImported(String source) =>
      _log('timetable_imported', <String, Object>{'source': source});

  @override
  Future<void> backupExported() => _log('backup_exported');

  @override
  Future<void> backupRestored() => _log('backup_restored');

  @override
  Future<void> undoUsed() => _log('undo_used');

  /// Never allowed to throw: a measurement failing is not a reason for a mark
  /// not to land, and there is nothing to retry or to tell the user.
  Future<void> _log(String name, [Map<String, Object>? parameters]) async {
    try {
      await _analytics.logEvent(name: name, parameters: parameters);
    } catch (_) {
      // Offline, or the SDK disabled itself.
    }
  }
}

class NoAnalytics implements Analytics {
  const NoAnalytics();

  @override
  Future<void> screen(String name) async {}

  @override
  Future<void> attendanceMarked() async {}

  @override
  Future<void> syncRan({required String target, required String outcome}) async {}

  @override
  Future<void> notionConnected() async {}

  @override
  Future<void> timetableImported(String source) async {}

  @override
  Future<void> backupExported() async {}

  @override
  Future<void> backupRestored() async {}

  @override
  Future<void> undoUsed() async {}
}
