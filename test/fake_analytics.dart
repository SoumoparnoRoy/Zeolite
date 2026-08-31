import 'package:zeolite/services/analytics_service.dart';

/// Records the event names in order, so a test can say what the app reported
/// without asserting on Firebase.
class FakeAnalytics implements Analytics {
  final List<String> events = <String>[];

  @override
  Future<void> screen(String name) async => events.add('screen:$name');

  @override
  Future<void> attendanceMarked() async => events.add('attendance_marked');

  @override
  Future<void> syncRan({
    required String target,
    required String outcome,
  }) async =>
      events.add('sync_ran:$target:$outcome');

  @override
  Future<void> notionConnected() async => events.add('notion_connected');

  @override
  Future<void> timetableImported(String source) async =>
      events.add('timetable_imported:$source');

  @override
  Future<void> backupExported() async => events.add('backup_exported');

  @override
  Future<void> backupRestored() async => events.add('backup_restored');

  @override
  Future<void> undoUsed() async => events.add('undo_used');
}
