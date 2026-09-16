import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/services/notification_service.dart';

/// For any test that drives `TimetableActions`, since every mutation
/// reschedules reminders.
class QuietNotifications extends NotificationService {
  QuietNotifications() : super.forTesting();

  @override
  Future<void> rescheduleAll({
    required AppSettings settings,
    required List<ClassSession> upcoming,
    required OverallStats stats,
  }) async {}

  @override
  Future<void> cancelAll() async {}
}
