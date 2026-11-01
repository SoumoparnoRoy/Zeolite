import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/services/firebase/app_check_starter.dart';
import 'package:zeolite/state/privacy_providers.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/state/sync_providers.dart';

import 'fake_notifications.dart';
import 'fake_sync_target.dart';

/// Activation no longer happens before runApp, and the scheduler's launch run
/// starts a microtask later; without the wait that run reaches Firestore with
/// no token, which an enforcing project refuses.
class _HeldAppCheck implements AppCheckStarter {
  final Completer<void> release = Completer<void>();

  @override
  Future<void> activate() => release.future;
}

void main() {
  late Directory dir;
  AppDatabase? appDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await SettingsService().save(const AppSettings(
        adult: true, shareUsage: false, sendCrashReports: false));
    dir = await Directory.systemTemp.createTemp('zeolite_app_check');
    appDb = AppDatabase.at('${dir.path}/a.db', factory: databaseFactoryFfi);
    await appDb!.database;
  });

  tearDown(() async {
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  test('an account sync waits for App Check before reaching the far side',
      () async {
    final FakeSyncTarget target = FakeSyncTarget();
    final _HeldAppCheck appCheck = _HeldAppCheck();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        notificationsProvider.overrideWithValue(QuietNotifications()),
        repositoryProvider.overrideWithValue(ZeoliteRepository(db: appDb!)),
        syncTargetProvider.overrideWithValue(target),
        appCheckStarterProvider.overrideWithValue(appCheck),
      ],
    );
    addTearDown(container.dispose);
    container.listen(appCheckProvider, (_, __) {});
    await container.read(settingsProvider.future);

    final Future<void> run = container.read(syncStatusProvider.notifier).run();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(target.calls, isEmpty, reason: 'App Check is still starting');

    appCheck.release.complete();
    await run;
    expect(target.calls, isNotEmpty);
  });
}
