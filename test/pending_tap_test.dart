import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/home_widget_service.dart';
import 'package:zeolite/state/home_widget_providers.dart';

/// The Today widget draws a tap before Dart saves it. Saving takes that back,
/// but must leave alone a later tap on the same class that is still on its
/// way, or the widget shows the earlier tap's status in between.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('home_widget');
  late Map<String, Object?> stored;

  setUp(() {
    stored = <String, Object?>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      final Map<Object?, Object?> args =
          (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
      switch (call.method) {
        case 'getWidgetData':
          return stored[args['id']];
        case 'saveWidgetData':
          final Object? data = args['data'];
          data == null
              ? stored.remove(args['id'])
              : stored[args['id'] as String] = data;
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void drawn(String key, int at) =>
      stored[HomeWidgetService.pendingMarkKey((key: key, at: '$at'))] =
          'present';

  Iterable<String> pending() =>
      stored.keys.where((String k) => k.startsWith('pendingMark:'));

  test('saving a tap takes back what was drawn for it and nothing else',
      () async {
    drawn('1:20261012:540', 100);
    drawn('2:20261012:600', 200);

    await const HomeWidgetService()
        .settleOnly((key: '1:20261012:540', at: '100'));

    expect(pending(), <String>['pendingMark:2:20261012:600@200']);
  });

  test('a later tap on the same class is left for its own run', () async {
    drawn('1:20261012:540', 100);
    drawn('1:20261012:540', 300);

    await const HomeWidgetService()
        .settleOnly((key: '1:20261012:540', at: '100'));

    expect(pending(), <String>['pendingMark:1:20261012:540@300']);
  });

  test('a tap with no stamp takes back nothing', () async {
    drawn('1:20261012:540', 300);

    await const HomeWidgetService()
        .settleOnly((key: '1:20261012:540', at: null));

    expect(pending(), hasLength(1));
  });

  test('the stamp the widget sends comes through on the request', () {
    final ExternalMarkRequest? request = ExternalMarkRequest.fromWidget(
      Uri.parse(
        'zeolite://mark?subject=1&date=20261012&start=540'
        '&status=present&drawn=1700000000000',
      ),
    );

    expect(request?.drawn, (key: '1:20261012:540', at: '1700000000000'));
  });
}
