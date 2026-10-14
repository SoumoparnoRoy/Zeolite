import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel =
      MethodChannel('dexterous.com/flutter/local_notifications');
  final List<String> asked = <String>[];

  setUp(() {
    asked.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      asked.add(call.method);
      return true;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // On Android 14+ the exact-alarm ask is a jump to a system screen, so it
  // must only come from the row that explains it, never after this prompt.
  test('allowing notifications does not also ask for exact alarms', () async {
    final bool granted =
        await NotificationService.forTesting().requestPermissions();

    expect(granted, isTrue);
    expect(asked, <String>['requestNotificationsPermission']);
  });
}
