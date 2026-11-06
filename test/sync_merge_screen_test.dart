import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/room.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/sync/sync_merge.dart';
import 'package:zeolite/domain/sync/sync_status.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/features/settings/sync_merge_screen.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/state/sync_providers.dart';
import 'package:zeolite/widgets/gradient_header.dart';

import 'fake_sync_target.dart';

const String _uuid = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';

SyncItem _mine(String key, {DateTime? changedAt}) => SyncItem(
      kind: SyncKind.attendance,
      localKey: key,
      fields: const <String, Object?>{'status': 'present', 'weight': 1},
      changedAt: changedAt,
    );

RemoteState _theirs(String key, {DateTime? editedAt}) => RemoteState(
      kind: SyncKind.attendance,
      localKey: key,
      remoteId: key,
      hash: 'account',
      fields: const <String, Object?>{'status': 'absent', 'weight': 1},
      editedAt: editedAt,
    );

/// Holds the merge open, the way a slow run does on a device.
class _HeldMerge extends SyncController {
  final Completer<SyncRunResult?> gate = Completer<SyncRunResult?>();
  int calls = 0;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<SyncRunResult?> merge(Map<String, SyncSide> decisions) {
    calls++;
    return gate.future;
  }
}

void main() {
  testWidgets('a double tap on Merge merges once and closes one screen',
      (WidgetTester tester) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const String key = '$_uuid:20260304:540';
    final SyncMergePlan plan = SyncMergePlan.from(
      local: <SyncItem>[_mine(key)],
      remote: <RemoteState>[_theirs(key)],
    );
    final _HeldMerge held = _HeldMerge();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        syncCoordinatorProvider.overrideWith(
          (Ref ref) => SyncCoordinator(
            repository: ZeoliteRepository(),
            settings: ref.watch(settingsServiceProvider),
            target: FakeSyncTarget(),
          ),
        ),
        syncStatusProvider.overrideWith(() => held),
        timetableProvider.overrideWith(
          (Ref ref) async => const TimetableData(
            categories: <ClassCategory>[],
            rooms: <Room>[],
            subjects: <Subject>[
              Subject(id: 1, uuid: _uuid, name: 'Subject 1', colorValue: 0),
            ],
            slots: <ClassSlot>[],
            extras: <ExtraClass>[],
            holidays: <Holiday>[],
            records: [],
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SyncMergeScreen(plan: plan),
              ),
            ),
            child: const Text('Below'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Below'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All from this device'));
    await tester.pump();

    // Both inside one frame: this button swaps to the spinner with no scale-out,
    // so only a busy frame can let a second tap reach it.
    final Offset merge = tester.getCenter(find.text('Merge'));
    await tester.tapAt(merge);
    await tester.tapAt(merge);
    await tester.pump();
    held.gate.complete(null);
    await tester.pumpAndSettle();

    expect(held.calls, 1);
    expect(find.text('Below'), findsOneWidget);
  });

  testWidgets('merge waits until every disagreement has an answer',
      (WidgetTester tester) async {
    const List<String> keys = <String>[
      '$_uuid:20260304:540',
      '$_uuid:20260305:540',
    ];
    // Only the first row is dated on both sides, so only it gets the hint.
    final SyncMergePlan plan = SyncMergePlan.from(
      local: <SyncItem>[
        _mine(keys[0], changedAt: DateTime(2026, 3, 4, 9)),
        _mine(keys[1]),
      ],
      remote: <RemoteState>[
        _theirs(keys[0], editedAt: DateTime(2026, 3, 4, 18)),
        _theirs(keys[1]),
      ],
    );

    // Tall enough that the floating Merge button covers none of the rows.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        timetableProvider.overrideWith(
          (Ref ref) async => const TimetableData(
            categories: <ClassCategory>[],
            rooms: <Room>[],
            subjects: <Subject>[
              Subject(id: 1, uuid: _uuid, name: 'Subject 1', colorValue: 0),
            ],
            slots: <ClassSlot>[],
            extras: <ExtraClass>[],
            holidays: <Holiday>[],
            records: [],
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: SyncMergeScreen(plan: plan),
      ),
    ));
    await tester.pumpAndSettle();

    GradientFab merge() => tester.widget<GradientFab>(find.byType(GradientFab));

    expect(merge().onPressed, isNull);
    expect(merge().label, 'Merge — 2 left to choose');
    expect(find.text('Changed more recently'), findsOneWidget);

    await tester.tap(find.text('Your account').first);
    await tester.pump();
    expect(merge().label, 'Merge — 1 left to choose');
    expect(merge().onPressed, isNull);

    await tester.tap(find.text('All from this device'));
    await tester.pump();
    expect(merge().label, 'Merge');
    expect(merge().onPressed, isNotNull);
    expect(find.text('2 rows sent up to your account'), findsOneWidget);
  });
}
