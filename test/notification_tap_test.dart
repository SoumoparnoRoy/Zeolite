import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/app.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/state/home_widget_providers.dart';

String? _screenFor(String? payload) {
  final int? tab = RootShell.tabForPayload(payload);
  return tab == null ? null : RootShell.tabNames[tab];
}

String? _screenForLink(String uri) {
  final int? tab = RootShell.tabForLink(Uri.parse(uri));
  return tab == null ? null : RootShell.tabNames[tab];
}

void main() {
  group('a tapped notification', () {
    test('opens the screen that answers it', () {
      expect(_screenFor('danger'), 'stats');
      expect(_screenFor('evening'), 'today');
      expect(_screenFor('class:2026-08-19|1'), 'today');
    });

    test('leaves the app where it is when the payload means nothing', () {
      // A payload in the tray outlives the build that wrote it.
      expect(RootShell.tabForPayload(null), isNull);
      expect(RootShell.tabForPayload('danger:7'), isNull);
      expect(RootShell.tabForPayload(''), isNull);
    });
  });

  group('a tapped widget', () {
    test('opens the screen it is a view of', () {
      expect(_screenForLink('zeolite://open?tab=today'), 'today');
      expect(_screenForLink('zeolite://open?tab=timetable'), 'timetable');
      expect(_screenForLink('zeolite://open?tab=stats'), 'stats');
    });

    test('leaves the app where it is when the link means nothing', () {
      // A widget outlives the build that placed it, so an unknown tab must
      // not fall through to tab zero.
      expect(RootShell.tabForLink(null), isNull);
      expect(_screenForLink('zeolite://open'), isNull);
      expect(_screenForLink('zeolite://open?tab=inbox'), isNull);
      expect(_screenForLink('zeolite://notion?session=abc'), isNull);
      expect(_screenForLink('zeolite://mark?subject=1'), isNull);
    });
  });

  group('a notification attendance action', () {
    test('reads the occurrence and requested status from the response', () {
      const NotificationResponse response = NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'present',
        payload: 'class:7:20260912:540',
      );

      final ExternalMarkRequest? request =
          ExternalMarkRequest.fromNotification(response);
      expect(request?.subjectId, 7);
      expect(request?.dateKey, 20260912);
      expect(request?.startMinutes, 540);
      expect(request?.status, AttendanceStatus.present);
    });

    test('refuses stale or malformed responses', () {
      const NotificationResponse wrongAction = NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'late',
        payload: 'class:7:20260912:540',
      );
      const NotificationResponse wrongPayload = NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: 'absent',
        payload: 'evening',
      );

      expect(ExternalMarkRequest.fromNotification(wrongAction), isNull);
      expect(ExternalMarkRequest.fromNotification(wrongPayload), isNull);
    });
  });
}
