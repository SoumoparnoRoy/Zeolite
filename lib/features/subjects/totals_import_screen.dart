import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/words.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_totals_import.dart';
import '../../domain/attendance_totals_ocr.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';

/// What a portal page would do to the subjects, row by row, before it does it.
///
/// The same shape as the paste import's preview: nothing is written until a
/// human has read the rows. What it adds is the row that cannot simply be
/// applied — a [TotalsMatch.overlap] — which starts out excluded and says why.
class TotalsImportScreen extends ConsumerStatefulWidget {
  const TotalsImportScreen({super.key, required this.totals});

  final AttendanceTotals totals;

  @override
  ConsumerState<TotalsImportScreen> createState() => _TotalsImportScreenState();
}

class _TotalsImportScreenState extends ConsumerState<TotalsImportScreen> {
  final Set<int> _excluded = <int>{};
  bool _seeded = false;
  bool _saving = false;

  /// Rows that would overwrite something, or that contradict themselves, start
  /// out unticked. Everything else is ready to go.
  ///
  /// Held back until the subjects have loaded: against an empty database every
  /// row looks new, and seeding from that would tick the conflicts.
  void _seed(TotalsPlan plan, {required bool ready}) {
    if (_seeded || !ready) return;
    _seeded = true;
    for (int i = 0; i < plan.rows.length; i++) {
      final TotalsPlanRow row = plan.rows[i];
      if (row.match == TotalsMatch.overlap || !row.row.isTrustworthy) {
        _excluded.add(i);
      }
    }
  }

  Future<void> _apply(TotalsPlan plan) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _saving = true);

    final List<TotalsDecision> decisions = <TotalsDecision>[
      for (int i = 0; i < plan.rows.length; i++)
        if (!_excluded.contains(i))
          TotalsDecision(
            row: plan.rows[i].row,
            subjectId: plan.rows[i].subject?.id,
            clearMarks: plan.rows[i].match == TotalsMatch.overlap,
          ),
    ];

    final TimetableActions actions = ref.read(actionsProvider);
    final int count = await actions.importAttendanceTotals(decisions);
    if (!mounted) return;
    navigator.pop();
    showUndoSnack(
      messenger,
      actions,
      'Brought in ${Words.plural(count, 'subject')}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final TimetableData? data = ref.watch(timetableProvider).value;
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();

    final Map<int, int> marks = <int, int>{};
    for (final AttendanceRecord record in data?.records ?? const <AttendanceRecord>[]) {
      if (!settings.countsInTerm(record.date)) continue;
      marks[record.subjectId] = (marks[record.subjectId] ?? 0) + 1;
    }

    final TotalsPlan plan = TotalsPlan.from(
      rows: widget.totals.rows,
      subjects: data?.subjects ?? const <Subject>[],
      marksBySubject: marks,
    );
    _seed(plan, ready: data != null);

    final int chosen = plan.rows.length - _excluded.length;

    return PushScaffold(
      title: 'Attendance so far',
      subtitle: '${Words.plural(plan.rows.length, 'course')} read · '
          '$chosen to bring in',
      floatingActionButton: chosen == 0 || _saving
          ? null
          : GradientFab(
              label: 'Bring in $chosen',
              onPressed: () => _apply(plan),
            ),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          sliver: SliverList.list(
            children: <Widget>[
              if (!widget.totals.addsUp) _ChecksumWarning(totals: widget.totals),
              const SectionHeader('What was read'),
              for (int i = 0; i < plan.rows.length; i++) ...<Widget>[
                _RowCard(
                  row: plan.rows[i],
                  excluded: _excluded.contains(i),
                  onToggle: () => setState(() {
                    if (!_excluded.remove(i)) _excluded.add(i);
                  }),
                ),
                const SizedBox(height: 10),
              ],
              Text(
                'Held and attended replace what the subject carries; the term '
                'total is what "still to come" counts down from.',
                style: TextStyle(fontSize: 12, height: 1.45, color: p.textFaint),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The page prints its own totals at the foot, so they can be added up and
/// checked. A mismatch means a row was missed or misread even when every row
/// agrees with its own percentage.
class _ChecksumWarning extends StatelessWidget {
  const _ChecksumWarning({required this.totals});

  final AttendanceTotals totals;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final List<String> parts = <String>[
      if (totals.printedTotal != null &&
          totals.printedTotal != totals.totalSum)
        'sessions add to ${totals.totalSum}, the page says '
            '${totals.printedTotal}',
      if (totals.printedAttended != null &&
          totals.printedAttended != totals.attendedSum)
        'attended adds to ${totals.attendedSum}, the page says '
            '${totals.printedAttended}',
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'This does not add up',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: p.absent,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '${parts.join(', and ')}. A row was probably missed — check '
              'against the page before bringing anything in.',
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.row,
    required this.excluded,
    required this.onToggle,
  });

  final TotalsPlanRow row;
  final bool excluded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final TotalsRow figures = row.row;

    // Nothing to bring in and nothing to correct by hand, so unlike the other
    // refusals this one cannot be ticked back on.
    final bool refused = figures.numbersUnread;

    final String? warning = figures.namesTwoCourses
        ? 'Two courses ran together here, so one of them lost its numbers. '
            'Read the page again from a larger image.'
        : refused
        ? 'The numbers beside this course could not be read, so there is '
            'nothing to bring in. Read the page again from a larger image.'
        : !figures.isOrdered
        ? 'More attended than held — one of the three was misread.'
        : !figures.percentAgrees
            ? 'The page prints ${figures.printedPercent}% here, which these '
                'numbers do not give. Something was misread.'
            : row.match == TotalsMatch.overlap
                ? 'You have marked '
                    '${Words.plural(row.marksInTerm, 'class', 'classes')} '
                    'here. The page counts those too, so bringing this row in '
                    'replaces them rather than adding to them.'
                : null;

    return SurfaceCard(
      onTap: refused ? null : onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Checkbox.adaptive(
                value: !excluded,
                onChanged: refused ? null : (_) => onToggle(),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  figures.subject,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: excluded ? p.textFaint : p.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Pill(
                label: switch (row.match) {
                  TotalsMatch.create => 'NEW',
                  TotalsMatch.update => 'UPDATE',
                  TotalsMatch.overlap => 'CONFLICT',
                },
                color: switch (row.match) {
                  TotalsMatch.create => p.present,
                  TotalsMatch.update => p.textTertiary,
                  TotalsMatch.overlap => p.warning,
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            refused
                ? 'numbers unread'
                    '${row.current == null ? '' : '  (now ${row.current})'}'
                : '${figures.attended} of ${figures.held} attended · '
                    '${figures.expectedTotal == null ? 'term total unread' : '${figures.expectedTotal} all term'}'
                    '${row.current == null ? '' : '  (now ${row.current})'}',
            style: monoStyle(color: p.textTertiary, size: 10.5),
          ),
          if (warning != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              warning,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: figures.isTrustworthy ? p.warning : p.absent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
