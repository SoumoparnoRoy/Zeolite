import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/home_widget_service.dart';
import 'package:zeolite/state/actions/action_core.dart';
import 'package:zeolite/state/home_widget_providers.dart';

class _CountingCore extends ActionCore {
  _CountingCore(super.ref);

  int reloads = 0;

  @override
  Future<void> reloadAfterWidgetMark() async => reloads++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('home_widget');
  late Map<String, Object?> stored;
  late ProviderContainer container;
  late _CountingCore core;

  setUp(() {
    stored = <String, Object?>{HomeWidgetService.markEpochKey: '1'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      final Map<Object?, Object?> args =
          (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
      return call.method == 'getWidgetData' ? stored[args['id']] : null;
    });
    container = ProviderContainer(
      overrides: [
        actionCoreProvider.overrideWith((Ref ref) => core = _CountingCore(ref)),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a mark written while the app runs reloads it with no resume', () async {
    container.read(homeWidgetMarkWatcherProvider);
    await settle();
    container.read(actionCoreProvider);
    expect(core.reloads, 0);

    stored[HomeWidgetService.markEpochKey] = '2';
    announceExternalMark();
    await settle();
    expect(core.reloads, 1);
  });

  test('a write that lands before the first look is still reloaded', () async {
    // Written after the launch read the database, before the watcher started.
    stored[HomeWidgetService.markEpochKey] = '2';
    container.read(homeWidgetMarkWatcherProvider);
    await settle();
    container.read(actionCoreProvider);
    expect(core.reloads, 0);

    announceExternalMark();
    await settle();
    expect(core.reloads, 1);
  });
}
