import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/models/tag.dart';
import 'package:zeolite/features/today/session_card.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/widgets/tag_picker.dart';

const Subject _physics = Subject(
  id: 1,
  name: 'Physics',
  colorValue: AppColors.defaultSubjectColor,
);

ClassSession _session({AttendanceStatus? status, int? tagId}) {
  final DateTime date = DateTime(2026, 8, 19);
  return ClassSession(
    subject: _physics,
    date: date,
    startMinutes: 540,
    endMinutes: 600,
    slotId: 1,
    record: status == null
        ? null
        : AttendanceRecord(
            subjectId: 1,
            date: date,
            startMinutes: 540,
            status: status,
            tagId: tagId,
          ),
  );
}

Widget _host(SessionCard card) {
  return MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(body: SingleChildScrollView(child: card)),
  );
}

/// Captures what [TimetableActions.mark] forwarded, without a database behind
/// it. The point is the arguments `mark` builds, not the write itself.
class _RecordingActions extends TimetableActions {
  _RecordingActions(super.ref);

  int? seenTagId;
  AttendanceStatus? seenStatus;
  bool called = false;

  @override
  Future<void> setStatusAt({
    required int subjectId,
    required DateTime date,
    required int startMinutes,
    required AttendanceStatus? current,
    required AttendanceStatus status,
    int weight = 1,
    int? tagId,
  }) async {
    called = true;
    seenStatus = status;
    seenTagId = tagId;
  }
}

void main() {
  group('a tag on the class card', () {
    testWidgets('shows as a chip on the marked card', (tester) async {
      await tester.pumpWidget(
        _host(
          SessionCard(
            session: _session(status: AttendanceStatus.present, tagId: 1),
            use24Hour: true,
            tagName: 'Proxy',
            onMark: (_) {},
            onTag: () {},
          ),
        ),
      );

      expect(find.text('PROXY'), findsOneWidget);
    });

    testWidgets('is absent from an untagged class', (tester) async {
      await tester.pumpWidget(
        _host(
          SessionCard(
            session: _session(status: AttendanceStatus.present),
            use24Hour: true,
            onMark: (_) {},
            onTag: () {},
          ),
        ),
      );

      expect(find.text('PROXY'), findsNothing);
    });

    testWidgets('the three statuses are still all there', (tester) async {
      // The whole design rests on marking being untouched, so this is worth
      // asserting rather than assuming.
      await tester.pumpWidget(
        _host(
          SessionCard(
            session: _session(),
            use24Hour: true,
            onMark: (_) {},
            onTag: () {},
          ),
        ),
      );

      expect(find.text('Present'), findsOneWidget);
      expect(find.text('Absent'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
    });
  });

  group('the tag control', () {
    testWidgets('is hidden until the class is marked', (tester) async {
      await tester.pumpWidget(
        _host(
          SessionCard(
            session: _session(),
            use24Hour: true,
            onMark: (_) {},
            onTag: () {},
          ),
        ),
      );

      expect(find.byIcon(Icons.sell_outlined), findsNothing);
    });

    testWidgets('appears with the controls a marked card opens',
        (tester) async {
      await tester.pumpWidget(
        _host(
          SessionCard(
            session: _session(status: AttendanceStatus.absent),
            use24Hour: true,
            onMark: (_) {},
            onTag: () {},
          ),
        ),
      );

      // A marked card collapses to its verdict, so the controls — and the tag
      // button with them — are one tap away rather than always on screen.
      expect(find.byIcon(Icons.sell_outlined), findsNothing);
      await tester.tap(find.text('Marked absent'));
      await tester.pump();

      expect(find.byIcon(Icons.sell_outlined), findsOneWidget);
    });

    testWidgets('stays hidden when no tags are configured', (tester) async {
      // `onTag` is null exactly when the tag list is empty, so an install that
      // never opens the Tags setting sees no trace of the feature.
      await tester.pumpWidget(
        _host(
          SessionCard(
            session: _session(status: AttendanceStatus.present),
            use24Hour: true,
            onMark: (_) {},
          ),
        ),
      );

      expect(find.byIcon(Icons.sell_outlined), findsNothing);
    });

    testWidgets('opens the picker when tapped', (tester) async {
      int opened = 0;
      await tester.pumpWidget(
        _host(
          SessionCard(
            session: _session(status: AttendanceStatus.present),
            use24Hour: true,
            onMark: (_) {},
            onTag: () => opened++,
          ),
        ),
      );

      await tester.tap(find.text('Marked present'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.sell_outlined));
      await tester.pump();

      expect(opened, 1);
    });
  });

  group('changing the status', () {
    testWidgets('carries the existing tag across', (tester) async {
      // `setAttendance` replaces the whole row, so correcting Present to Absent
      // would drop the tag unless `mark` hands it back.
      late _RecordingActions actions;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            actionsProvider.overrideWith((Ref ref) {
              return actions = _RecordingActions(ref);
            }),
          ],
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              return _host(
                SessionCard(
                  session: _session(
                    status: AttendanceStatus.present,
                    tagId: 7,
                  ),
                  use24Hour: true,
                  tagName: 'Proxy',
                  onMark: (AttendanceStatus status) => ref
                      .read(actionsProvider)
                      .mark(
                        _session(status: AttendanceStatus.present, tagId: 7),
                        status,
                      ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Marked present'));
      await tester.pump();
      await tester.tap(find.text('Absent'));
      await tester.pump();

      expect(actions.called, isTrue);
      expect(actions.seenStatus, AttendanceStatus.absent);
      expect(actions.seenTagId, 7);
    });

    testWidgets('an untagged class forwards no tag', (tester) async {
      late _RecordingActions actions;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            actionsProvider.overrideWith((Ref ref) {
              return actions = _RecordingActions(ref);
            }),
          ],
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              return _host(
                SessionCard(
                  session: _session(),
                  use24Hour: true,
                  onMark: (AttendanceStatus status) =>
                      ref.read(actionsProvider).mark(_session(), status),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Present'));
      await tester.pump();

      expect(actions.called, isTrue);
      expect(actions.seenTagId, isNull);
    });
  });

  group('the tag picker', () {
    testWidgets('lists every tag and returns the tapped one', (tester) async {
      int? chosen;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  chosen = await showTagPicker(
                    context,
                    tags: const <Tag>[
                      Tag(id: 1, name: 'Proxy'),
                      Tag(id: 2, name: 'Online'),
                    ],
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Proxy'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);

      await tester.tap(find.text('Online'));
      await tester.pumpAndSettle();

      expect(chosen, 2);
    });

    testWidgets('says how to remove the tag already set', (tester) async {
      // The clear path is the same gesture as the status buttons, which is
      // only obvious if the sheet says so.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showTagPicker(
                  context,
                  tags: const <Tag>[Tag(id: 1, name: 'Proxy')],
                  selected: 1,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Tap the current tag to remove it.'), findsOneWidget);
    });
  });

  group('the time gutter', () {
    testWidgets('does not wrap a 12-hour time onto two lines', (tester) async {
      // The gutter was sized for "10:50" and wrapped every "10:00 am" into
      // three lines on the tablet.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          SessionCard(
            session: _session(),
            use24Hour: false,
            onMark: (_) {},
          ),
        ),
      );

      final double lineHeight = tester.getSize(find.text('9:00 am')).height;
      expect(lineHeight, lessThan(20));
    });
  });
}
