import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';
import 'package:zeolite/state/auth_providers.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/state/sync_providers.dart';

import 'fake_sync_target.dart';

class _SignedInAs implements User {
  _SignedInAs(this.uid);

  @override
  final String uid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Two ways a ledger stops describing the far side, both reported from a real
/// device: an account deleted and remade left every row looking pushed, and
/// "rewrite every row" forgot the ledger only to be asked whether it was sure.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ZeoliteRepository repo;
  late FakeSyncTarget target;
  AppDatabase? appDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_ledger');
    appDb = AppDatabase.at('${dir.path}/l.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    target = FakeSyncTarget()..trustsPulls = true;
    await repo.insertSubject(
      const Subject(
        name: 'Generic Course',
        code: 'GEN101',
        colorValue: 0xFF336699,
      ),
    );
  });

  tearDown(() async {
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  SyncCoordinator make() => SyncCoordinator(
        repository: repo,
        settings: SettingsService(),
        target: target,
      );

  /// The fake keeps what it was told to hold apart from what it hands back, so
  /// a far side holding the last run's work has to be rebuilt from the ledger.
  Future<void> farSideHoldsWhatWasPushed() async {
    final List<RemoteState> held = <RemoteState>[];
    for (final SyncKind kind in SyncKind.values) {
      for (final RemoteLink link in await repo.getRemoteLinks('fake', kind)) {
        held.add(
          RemoteState(
            kind: kind,
            localKey: link.localKey,
            remoteId: link.remoteId,
            hash: link.remoteHash,
            fields: const <String, Object?>{},
          ),
        );
      }
    }
    target.remote = held;
  }

  test('an account emptied under the ledger is filled again', () async {
    target.recreatesMissingRows = true;
    expect((await make().run(force: true)).pushed, greaterThan(0));
    await farSideHoldsWhatWasPushed();

    // The account was deleted and a new one connected: the far side is empty,
    // and nothing has touched the links.
    target.remote = <RemoteState>[];
    final SyncRunResult second = await make().run(force: true);

    expect(second.outcome, SyncRunOutcome.synced);
    expect(second.pushed, greaterThan(0),
        reason: 'the new account has to be filled, not reported clean');
  });

  test('a page deleted by hand is left deleted', () async {
    target.recreatesMissingRows = false;
    await make().run(force: true);
    await farSideHoldsWhatWasPushed();

    target.remote = <RemoteState>[];
    expect((await make().run(force: true)).pushed, 0,
        reason: 'somebody removed those pages on purpose');
  });

  test('rewriting every row rewrites rather than asking', () async {
    await make().run(force: true);
    await farSideHoldsWhatWasPushed();

    // What "rewrite every row" does before it runs.
    await repo.deleteRemoteLinksFor('fake');
    final SyncRunResult rewritten = await make().run(force: true, rewrite: true);

    expect(rewritten.outcome, SyncRunOutcome.synced);
    expect(rewritten.pushed, greaterThan(0));
  });

  test('an ordinary run still asks when both sides hold something', () async {
    await make().run(force: true);
    await farSideHoldsWhatWasPushed();

    await repo.deleteRemoteLinksFor('fake');
    expect(
      (await make().run(force: true)).outcome,
      SyncRunOutcome.reviewNeeded,
    );
  });

  test('signing into a different account forgets the old ledger', () async {
    // Off, so only the ledger being forgotten can explain a push.
    target.recreatesMissingRows = false;

    ProviderContainer as(String uid) {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          syncTargetProvider.overrideWithValue(target),
          signedInUserProvider.overrideWith(
            (Ref ref) => Stream<User?>.value(_SignedInAs(uid)),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(signedInUserProvider, (_, __) {});
      return container;
    }

    final ProviderContainer first = as('uid-first');
    await first.read(signedInUserProvider.future);
    await first.read(settingsProvider.future);
    expect(
      (await first.read(syncStatusProvider.notifier).run(force: true))!.pushed,
      greaterThan(0),
    );
    await farSideHoldsWhatWasPushed();

    // That account is deleted and another connected.
    target.remote = <RemoteState>[];
    final ProviderContainer second = as('uid-second');
    await second.read(signedInUserProvider.future);
    await second.read(settingsProvider.future);
    final SyncRunResult? result =
        await second.read(syncStatusProvider.notifier).run(force: true);

    expect(result?.pushed, greaterThan(0));
    expect(
      second.read(settingsProvider).value?.syncedAccountId,
      'uid-second',
    );
  });
}
