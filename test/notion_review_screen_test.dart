import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/room.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/sync/sync_plan.dart';
import 'package:zeolite/domain/sync/sync_status.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/features/settings/notion_review_screen.dart';
import 'package:zeolite/state/notion_sync_providers.dart';
import 'package:zeolite/state/providers.dart';

const String _uuid = 'subject-uuid';
final DateTime _day = DateTime(2026, 3, 4);

/// Holds the rows the screen reads, without a coordinator behind it.
class _StaticSync extends NotionSyncController {
  _StaticSync(this.pulls);

  final List<SyncPull> pulls;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  List<SyncPull> get review => pulls;
}

SyncPull _pull({required String key, String status = 'cancelled'}) => SyncPull(
      remote: RemoteState(
        kind: SyncKind.attendance,
        localKey: key,
        remoteId: 'page-1',
        hash: 'h',
        fields: <String, Object?>{'status': status, 'weight': 0},
      ),
    );

TimetableData _data({required List<AttendanceRecord> records}) => TimetableData(
      categories: const <ClassCategory>[],
      rooms: const <Room>[],
      subjects: const <Subject>[
        Subject(
          id: 1,
          uuid: _uuid,
          name: 'Thermodynamics',
          colorValue: AppColors.defaultSubjectColor,
        ),
      ],
      slots: const <ClassSlot>[],
      extras: const <ExtraClass>[],
      holidays: const <Holiday>[],
      records: records,
    );

Widget _app(List<SyncPull> pulls, List<AttendanceRecord> records) =>
    ProviderScope(
      overrides: [
        timetableProvider.overrideWith((Ref ref) async => _data(records: records)),
        notionSyncStatusProvider.overrideWith(() => _StaticSync(pulls)),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const NotionReviewScreen(),
      ),
    );

void main() {
  testWidgets('a row says what is marked here, not only what Notion sent',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      <SyncPull>[_pull(key: SyncItem.keyFor(_uuid, _day, 540))],
      <AttendanceRecord>[
        AttendanceRecord(
          subjectId: 1,
          date: _day,
          startMinutes: 540,
          status: AttendanceStatus.present,
        ),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Notion says Cancelled'), findsOneWidget);
    expect(find.textContaining('Here it is Present'), findsOneWidget);
  });

  testWidgets('a row with no mark here says so', (WidgetTester tester) async {
    // The case that cost an evening: a page whose mark does not exist here
    // cannot be answered by keeping a local mark, and the screen used to give
    // no sign of it at all.
    await tester.pumpWidget(_app(
      <SyncPull>[_pull(key: SyncItem.keyFor(_uuid, _day, 600))],
      const <AttendanceRecord>[],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Not marked on this device'), findsOneWidget);
  });
}
