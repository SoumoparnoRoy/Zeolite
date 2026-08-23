import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/services/notification_service.dart';

ClassSession _session({String? room, String? teacher}) {
  return ClassSession(
    subject: Subject(
      id: 1,
      name: 'Physics',
      teacher: teacher,
      colorValue: AppColors.defaultSubjectColor,
    ),
    date: DateTime(2026, 8, 19),
    startMinutes: 9 * 60,
    endMinutes: 10 * 60,
    room: room,
    slotId: 1,
  );
}

SubjectStats _stats({int present = 0, int absent = 0, double target = 0.75}) {
  return SubjectStats(
    subject: const Subject(
      id: 1,
      name: 'Physics',
      colorValue: AppColors.defaultSubjectColor,
    ),
    present: present,
    absent: absent,
    cancelled: 0,
    target: target,
    remainingPlanned: 20,
  );
}

void main() {
  group('the detail line', () {
    test('names the time, the room and the teacher', () {
      expect(
        NotificationService.reminderDetailLine(
          _session(room: 'LT-3', teacher: 'Dr A. Example'),
          use24Hour: false,
        ),
        '9:00 am · LT-3 · Dr A. Example',
      );
    });

    test('leaves out whatever the class does not have', () {
      expect(
        NotificationService.reminderDetailLine(
          _session(teacher: 'Dr A. Example'),
          use24Hour: false,
        ),
        '9:00 am · Dr A. Example',
      );
      expect(
        NotificationService.reminderDetailLine(
          _session(room: 'LT-3'),
          use24Hour: true,
        ),
        '09:00 · LT-3',
      );
      expect(
        NotificationService.reminderDetailLine(_session(), use24Hour: true),
        '09:00',
      );
    });

    test('an empty room or teacher counts as absent, not as a gap', () {
      // Both are free text, so "" reaches here as easily as null and would
      // otherwise show up as a trailing separator.
      expect(
        NotificationService.reminderDetailLine(
          _session(room: '', teacher: ''),
          use24Hour: true,
        ),
        '09:00',
      );
    });
  });

  group('the standing line', () {
    test('is the same sentence the rest of the app shows', () {
      final SubjectStats stats = _stats(present: 8, absent: 1);
      expect(
        NotificationService.reminderStandingLine(stats),
        stats.headline,
      );
      expect(NotificationService.reminderStandingLine(stats), isNotNull);
    });

    test('is dropped for a subject with nothing marked yet', () {
      // "No classes marked yet" is true but useless on a reminder for the
      // class you are walking into.
      expect(NotificationService.reminderStandingLine(_stats()), isNull);
    });

    test('is dropped when the subject is unknown', () {
      expect(NotificationService.reminderStandingLine(null), isNull);
    });

    test('reports recovery when below target', () {
      final String? line =
          NotificationService.reminderStandingLine(_stats(present: 1, absent: 3));
      expect(line, contains('brings you back to target'));
    });

    test('reports the skip allowance when comfortably above', () {
      final String? line =
          NotificationService.reminderStandingLine(_stats(present: 20, absent: 1));
      expect(line, contains('skip'));
    });
  });

  group('cancelled classes', () {
    test('do not count towards either side of the standing line', () {
      // Guards the one place the notification could disagree with the Stats
      // screen: both read the same SubjectStats.
      final SubjectStats stats = SubjectStats(
        subject: const Subject(
          id: 1,
          name: 'Physics',
          colorValue: AppColors.defaultSubjectColor,
        ),
        present: 3,
        absent: 1,
        cancelled: 5,
        target: 0.75,
        remainingPlanned: 10,
      );
      expect(stats.held, 4);
      expect(NotificationService.reminderStandingLine(stats), stats.headline);
    });
  });
}
