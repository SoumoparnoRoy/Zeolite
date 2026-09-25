import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/services/notification_service.dart';

AndroidNotificationChannel _channel(String id, Importance importance) =>
    AndroidNotificationChannel(id, id, importance: importance);

/// What decides whether Settings has anything to warn about.
void main() {
  test('a channel set to none is blocked on its own', () {
    final TrayAccess access = NotificationService.trayAccessFrom(
      appAllowed: true,
      channels: <AndroidNotificationChannel>[
        _channel('attend_it_classes', Importance.high),
        _channel('attend_it_reminders', Importance.none),
        // Not one of the app's own, so it cannot block anything here.
        _channel('miscellaneous', Importance.none),
      ],
    );

    expect(access.blocked, <TrayChannel>{TrayChannel.reminders});
    expect(access.blocksOnly(TrayChannel.reminders), isTrue);
    expect(access.allows(TrayChannel.classes), isTrue);
  });

  test('with the whole app blocked no channel is singled out', () {
    final TrayAccess access = NotificationService.trayAccessFrom(
      appAllowed: false,
      channels: <AndroidNotificationChannel>[
        _channel('attend_it_alerts', Importance.none),
      ],
    );

    expect(access.allows(TrayChannel.classes), isFalse);
    expect(access.blocksOnly(TrayChannel.alerts), isFalse);
  });

  test('a platform that cannot answer is taken as open', () {
    final TrayAccess access = NotificationService.trayAccessFrom(
      appAllowed: null,
      channels: null,
    );

    expect(access.allows(TrayChannel.alerts), isTrue);
  });
}
