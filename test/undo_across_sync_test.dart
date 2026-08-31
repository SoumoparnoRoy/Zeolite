import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/state/sync_providers.dart';

import 'fake_sync_target.dart';

/// Pins the bug this file exists for: an Undo offer died about fifteen seconds
/// after the tap that raised it, because the debounced sync run that the same
/// tap scheduled pulled a row and reloaded.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ZeoliteRepository repo;
  late FakeSyncTarget target;
  late ProviderContainer container;
  AppDatabase? appDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_undo_sync');
    appDb = AppDatabase.at('${dir.path}/undo.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    target = FakeSyncTarget()..trustsPulls = true;

    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        syncTargetProvider.overrideWithValue(target),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  RemoteState arriving(String key, String name) => RemoteState(
        kind: SyncKind.subject,
        localKey: key,
        remoteId: key,
        hash: 'hash-$key',
        fields: <String, Object?>{
          'name': name,
          'code': 'GEN202',
          'teacher': null,
          'color': 0xFF112233,
          'targetPercent': null,
          'priorHeld': 0,
          'priorAttended': 0,
          'expectedTotal': null,
        },
      );

  /// Two subjects, a first run to reconcile them, then the deletion of one —
  /// which is what arms the snapshot the tests are about. Returns the uuid of
  /// the one left alone, whose ledger entry the second test expects to survive.
  Future<String> deleteAfterReconciling() async {
    final int doomed = await repo.insertSubject(
      const Subject(
        name: 'Generic Course',
        code: 'GEN101',
        colorValue: 0xFF336699,
      ),
    );
    final int kept = await repo.insertSubject(
      const Subject(
        name: 'Second Course',
        code: 'GEN102',
        colorValue: 0xFF993366,
      ),
    );
    await container.read(settingsProvider.future);
    container.listen(timetableProvider, (_, __) {});
    await container.read(timetableProvider.future);
    await container.read(syncStatusProvider.notifier).run(force: true);

    final String uuid = (await repo.getSubjects())
        .firstWhere((Subject s) => s.id == kept)
        .uuid!;
    await container.read(actionsProvider).deleteSubject(doomed);
    return uuid;
  }

  test('a pull that lands mid-offer does not take Undo with it', () async {
    await deleteAfterReconciling();
    final int? token = container.read(actionsProvider).pendingUndoToken;
    expect(token, isNotNull);

    target.remote = <RemoteState>[
      ...?target.remote,
      arriving('pulled1', 'Other Course'),
    ];
    final SyncRunResult? result =
        await container.read(syncStatusProvider.notifier).run(force: true);
    expect(result?.pulled, 1,
        reason: 'the pull has to land, or nothing is proved');

    expect(container.read(actionsProvider).pendingUndoToken, token);
    expect(await container.read(actionsProvider).undo(token!), isTrue);
  });

  test('undoing after a pull forgets only the rows that pull brought down',
      () async {
    final String uuid = await deleteAfterReconciling();
    final int token = container.read(actionsProvider).pendingUndoToken!;

    target.remote = <RemoteState>[
      ...?target.remote,
      arriving('pulled1', 'Other Course'),
    ];
    await container.read(syncStatusProvider.notifier).run(force: true);
    await container.read(actionsProvider).undo(token);

    final List<String> keys =
        (await repo.getRemoteLinks(target.id, SyncKind.subject))
            .map((RemoteLink link) => link.localKey)
            .toList();
    // Forgotten, so the next run pulls it back rather than reading it as
    // deleted here and archiving the far side's copy.
    expect(keys, isNot(contains('pulled1')));
    expect(keys, contains(uuid));
  });
}
