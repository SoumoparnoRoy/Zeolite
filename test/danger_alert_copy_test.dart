import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/services/notification_service.dart';

SubjectStats _stats({
  required int id,
  required String name,
  int present = 0,
  int absent = 0,
  double target = 0.75,
}) {
  return SubjectStats(
    subject: Subject(
      id: id,
      name: name,
      colorValue: AppColors.defaultSubjectColor,
    ),
    present: present,
    absent: absent,
    cancelled: 0,
    target: target,
    plannedFromSlots: 20,
  );
}

void main() {
  group('the warning message', () {
    test('has one shape either side of the target', () {
      // The on-target case used to get a sentence of its own, so the same
      // event was announced two different ways depending on the percentage.
      final String above = NotificationService.dangerMessage(
        _stats(id: 1, name: 'Alpha', present: 3, absent: 1),
      );
      final String below = NotificationService.dangerMessage(
        _stats(id: 2, name: 'Beta', present: 1, absent: 3),
      );
      expect(above, startsWith('75% · '));
      expect(below, startsWith('25% · '));
    });

    test('rounds the way every other screen does', () {
      final SubjectStats stats = _stats(id: 1, name: 'Alpha', present: 2, absent: 1);
      expect(stats.percent, closeTo(66.67, 0.01));
      expect(NotificationService.dangerMessage(stats), startsWith('67% · '));
    });

    test('is the sentence the rest of the app already shows', () {
      final SubjectStats stats = _stats(id: 1, name: 'Alpha', present: 1, absent: 3);
      expect(
        NotificationService.dangerMessage(stats),
        endsWith(stats.headline),
      );
    });
  });

  group('the warning heading', () {
    test('never names a subject, so one and several read alike', () {
      expect(NotificationService.dangerTitle(1), 'Worth a look');
      expect(NotificationService.dangerTitle(3), '3 subjects worth a look');
    });
  });

  group('the tray line', () {
    test('carries the name the dialog puts in its own row', () {
      final SubjectStats stats = _stats(id: 1, name: 'Alpha', present: 1, absent: 3);
      expect(
        NotificationService.dangerLine(stats),
        'Alpha · ${NotificationService.dangerMessage(stats)}',
      );
    });
  });
}
