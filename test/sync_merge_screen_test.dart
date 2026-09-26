import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/room.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/sync/sync_merge.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/features/settings/sync_merge_screen.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/widgets/gradient_header.dart';

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

void main() {
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
