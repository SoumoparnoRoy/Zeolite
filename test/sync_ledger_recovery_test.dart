import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
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
import 'package:zeolite/domain/sync/sync_merge.dart';
import 'package:zeolite/domain/sync/sync_status.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/auth_service.dart';
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
  Future<void> reload() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Signed in when another device deleted the account: the token still works,
/// but Firebase no longer knows the user.
class _DeletedElsewhere implements User {
  @override
  String get uid => 'uid-deleted';

  @override
  Future<void> reload() async =>
      throw FirebaseAuthException(code: 'user-not-found');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Unused implements FirebaseAuth, FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LedgerWontClear extends ZeoliteRepository {
  _LedgerWontClear({required super.db});

  @override
  Future<void> deleteRemoteLinksFor(String target) async =>
      throw StateError('disk full');
}

class _CountingSignOut extends AuthService {
  _CountingSignOut() : super(auth: _Unused(), firestore: _Unused());

  int signOuts = 0;

  @override
  Future<void> signOut() async => signOuts++;
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

  ProviderContainer signedIn(String uid, {ZeoliteRepository? repository}) {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repository ?? repo),
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
    final SyncRunResult rewritten =
        await make().run(force: true, rewrite: true);

    expect(rewritten.outcome, SyncRunOutcome.synced);
    expect(rewritten.pushed, greaterThan(0));
  });

  group('a first merge over what the account already holds', () {
    Future<int> linkCount() async {
      int n = 0;
      for (final SyncKind kind in SyncKind.values) {
        n += (await repo.getRemoteLinks('fake', kind)).length;
      }
      return n;
    }

    Future<void> connectedBefore() async {
      await make().run(force: true);
      await farSideHoldsWhatWasPushed();
      // A device meeting this account for the first time has no ledger.
      await repo.deleteRemoteLinksFor('fake');
      target.calls.clear();
    }

    test('links the identical rows without writing them', () async {
      await connectedBefore();
      final int rows = target.remote!.length;

      final SyncRunResult merged =
          await make().run(force: true, merge: const <String, SyncSide>{});

      expect(merged.outcome, SyncRunOutcome.synced);
      expect(merged.pushed, 0);
      expect(merged.linked, rows);
      expect(target.calls.where((String c) => c != 'fetch'), isEmpty);
      expect(await linkCount(), rows);

      // Linked properly: the next run has nothing left to do.
      final SyncRunResult next = await make().run(force: true);
      expect(next.pushed, 0);
      expect(next.linked, 0);
      expect(next.pulled, 0);
    });

    test('still writes a row that changed since', () async {
      await connectedBefore();
      final Subject subject = (await repo.getSubjects()).single;
      await repo.updateSubject(subject.copyWith(name: 'Generic Course 2'));

      final SyncRunResult merged = await make().run(
        force: true,
        merge: <String, SyncSide>{subject.uuid!: SyncSide.here},
      );

      expect(merged.pushed, 1);
      expect(merged.linked, target.remote!.length - 1);
      expect(target.calls, contains(startsWith('update')));
    });

    test('still writes where pulls are not trusted', () async {
      await connectedBefore();
      target.trustsPulls = false;

      final SyncRunResult merged =
          await make().run(force: true, merge: const <String, SyncSide>{});

      expect(merged.linked, 0);
      expect(merged.pushed, greaterThan(0));
    });
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

    final ProviderContainer first = signedIn('uid-first');
    await first.read(signedInUserProvider.future);
    await first.read(settingsProvider.future);
    expect(
      (await first.read(syncStatusProvider.notifier).run(force: true))!.pushed,
      greaterThan(0),
    );
    await farSideHoldsWhatWasPushed();

    // That account is deleted and another connected.
    target.remote = <RemoteState>[];
    final ProviderContainer second = signedIn('uid-second');
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

  // The second tap used to slip past the running check while the first was
  // still writing which account the ledger belongs to.
  test('a double tap on the first sync with an account runs once', () async {
    final ProviderContainer container = signedIn('uid-new');
    await container.read(signedInUserProvider.future);
    await container.read(settingsProvider.future);
    final SyncController sync = container.read(syncStatusProvider.notifier);

    final List<SyncRunResult?> results = await Future.wait(
      <Future<SyncRunResult?>>[sync.run(force: true), sync.run(force: true)],
    );
    // A rerun queued by the coordinator is nobody's future, so give one the
    // time to show up before counting.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(results.whereType<SyncRunResult>(), hasLength(1));
    expect(target.calls.where((String c) => c == 'fetch'),
        hasLength(target.kinds.length),
        reason: 'the coordinator ran once');
    expect(container.read(syncStatusProvider).state, isNot(SyncState.running));
  });

  test('a ledger that cannot be cleared does not leave the sync running',
      () async {
    final ProviderContainer before = signedIn('uid-first');
    await before.read(signedInUserProvider.future);
    await before.read(settingsProvider.future);
    await before.read(syncStatusProvider.notifier).run(force: true);

    final ProviderContainer after = signedIn(
      'uid-second',
      repository: _LedgerWontClear(db: appDb!),
    );
    await after.read(signedInUserProvider.future);
    await after.read(settingsProvider.future);

    await expectLater(
      after.read(syncStatusProvider.notifier).run(force: true),
      throwsStateError,
    );
    expect(after.read(syncStatusProvider).state, isNot(SyncState.running));
  });

  test('an account deleted from another device is signed out, not refilled',
      () async {
    final _CountingSignOut auth = _CountingSignOut();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        syncTargetProvider.overrideWithValue(target),
        authServiceProvider.overrideWithValue(auth),
        signedInUserProvider.overrideWith(
          (Ref ref) => Stream<User?>.value(_DeletedElsewhere()),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(signedInUserProvider, (_, __) {});
    await container.read(signedInUserProvider.future);
    await container.read(settingsProvider.future);

    final SyncRunResult? result =
        await container.read(syncStatusProvider.notifier).run(force: true);

    expect(result, isNull);
    expect(auth.signOuts, 1);
    expect(await repo.getRemoteLinks('fake', SyncKind.subject), isEmpty,
        reason: 'nothing was pushed to the deleted account');
  });

  test('only a definite answer counts as deleted', () async {
    expect(await AuthService.isDeleted(_DeletedElsewhere()), isTrue);
    expect(await AuthService.isDeleted(_SignedInAs('uid-live')), isFalse);
  });
}
