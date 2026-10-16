import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/home_widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('home_widget');
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> push(String verdict) => const HomeWidgetService().push(
        today: const <String, Object?>{'days': <Object?>[]},
        standing: <String, Object?>{'verdict': verdict},
        subjects: const <String, Object?>{'subjects': <Object?>[]},
        theme: null,
        classStarts: const <DateTime>[],
      );

  test('the same payload twice is written and drawn once', () async {
    await push('All on target');
    final int first = calls.length;
    expect(first, greaterThan(0));

    await push('All on target');
    expect(calls.length, first);

    await push('One subject below target');
    expect(calls.where((String m) => m == 'saveWidgetData'), isNotEmpty);
    expect(calls.length, greaterThan(first));
  });
}
