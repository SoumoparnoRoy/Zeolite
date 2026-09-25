import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/services/notification_service.dart';

const Subject _subject = Subject(
  id: 1,
  name: 'Subject 1',
  colorValue: AppColors.defaultSubjectColor,
);

ClassSession _session(
  DateTime date,
  int startHour, {
  AttendanceStatus? marked,
}) {
  return ClassSession(
    subject: _subject,
    date: date,
    startMinutes: startHour * 60,
    endMinutes: startHour * 60 + 60,
    slotId: 1,
    record: marked == null
        ? null
        : AttendanceRecord(
            subjectId: 1,
            date: date,
            startMinutes: startHour * 60,
            status: marked,
          ),
  );
}

/// The evening reminder goes off only on a day that still has something to
/// mark, and says how much.
void main() {
  final DateTime monday = DateTime(2026, 9, 21);
  final DateTime tuesday = DateTime(2026, 9, 22);
  const int eight = 20 * 60;

  test('counts only unmarked classes that are over by the reminder', () {
    final Map<int, int> counts = NotificationService.eveningCounts(
      <ClassSession>[
        _session(monday, 9),
        _session(monday, 11, marked: AttendanceStatus.present),
        _session(monday, 14),
        // Ends at 22:00, after the reminder has gone off.
        _session(monday, 21),
        // Marked ahead, the way a cancelled class often is.
        _session(tuesday, 9, marked: AttendanceStatus.cancelled),
      ],
      reminderMinutes: eight,
    );

    expect(counts, <int, int>{Dates.keyOf(monday): 2});
  });

  test('a day with no classes, or all of them marked, has no reminder', () {
    final Map<int, int> counts = NotificationService.eveningCounts(
      <ClassSession>[
        _session(monday, 9, marked: AttendanceStatus.absent),
      ],
      reminderMinutes: eight,
    );

    expect(counts[Dates.keyOf(monday)], isNull);
    expect(counts[Dates.keyOf(tuesday)], isNull);
    expect(
      NotificationService.decideEvening(count: 0, due: true, shown: true),
      EveningReminder.cancel,
    );
  });

  test('one shown in the tray stays until the last class is marked', () {
    expect(
      NotificationService.decideEvening(count: 1, due: true, shown: true),
      EveningReminder.refresh,
    );
    // Swiped away: marking another class does not bring it back.
    expect(
      NotificationService.decideEvening(count: 1, due: true, shown: false),
      EveningReminder.leave,
    );
    expect(
      NotificationService.decideEvening(count: 3, due: false, shown: false),
      EveningReminder.schedule,
    );
  });

  test('says how many are left', () {
    expect(NotificationService.eveningBody(1), '1 class still unmarked');
    expect(NotificationService.eveningBody(3), '3 classes still unmarked');
  });
}
