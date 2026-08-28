import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../domain/sync/sync_merge.dart';
import '../../domain/sync/sync_target.dart';
import '../../services/sync/sync_coordinator.dart';
import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';

/// What signing in would do when the device and the account both already hold
/// attendance, before it does it.
///
/// Only the contested rows are listed. Everything else has one possible
/// reading — a row only this device has goes up, a row only the account has
/// comes down — and listing those would bury the handful of decisions that
/// actually need a person under a term of ones that do not.
class SyncMergeScreen extends ConsumerStatefulWidget {
  const SyncMergeScreen({super.key, required this.plan});

  final SyncMergePlan plan;

  @override
  ConsumerState<SyncMergeScreen> createState() => _SyncMergeScreenState();
}

class _SyncMergeScreenState extends ConsumerState<SyncMergeScreen> {
  late Map<String, SyncSide> _choices = widget.plan.defaults;
  bool _merging = false;

  Future<void> _merge() async {
    if (ref.read(syncCoordinatorProvider) == null) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _merging = true);

    final TimetableActions actions = ref.read(actionsProvider);
    final SyncRunResult? result =
        await ref.read(syncStatusProvider.notifier).merge(_choices);
    if (!mounted || result == null) return;

    navigator.pop();
    showUndoSnack(
      messenger,
      actions,
      result.ok
          ? 'Merged. ${Words.plural(result.pushed, 'row')} sent, '
              '${Words.plural(result.pulled, 'row')} brought down.'
          : 'The merge did not finish. Nothing on this device changed.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final SyncMergePlan plan = widget.plan;
    final List<Subject> subjects =
        ref.watch(timetableProvider).value?.subjects ?? const <Subject>[];
    final Map<String, String> names = _namesByUuid(plan, subjects);

    final int fromAccount = _choices.values
        .where((SyncSide side) => side == SyncSide.there)
        .length;

    return PushScaffold(
      title: 'Two sets of history',
      subtitle: plan.differing.isEmpty
          ? 'Nothing to decide'
          : '${Words.plural(plan.differing.length, 'disagreement')} to settle',
      floatingActionButton: _merging
          ? null
          : GradientFab(label: 'Merge', onPressed: _merge),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          sliver: SliverList.list(
            children: <Widget>[
              const _Hint(
                'This device and your account were both used before they were '
                'connected, so neither one is simply right. Nothing is written '
                'until you merge, and a merge can be undone.',
              ),
              const SizedBox(height: AppSpacing.md),
              _Summary(plan: plan, fromAccount: fromAccount),
              if (plan.differing.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.xl),
                const SectionHeader('Where they disagree'),
                const _Hint(
                  'Each starts on whichever side was changed more recently.',
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final SyncMergeRow row in plan.differing)
                  _RowCard(
                    row: row,
                    name: _titleOf(row, names),
                    side: _choices[row.localKey] ?? SyncSide.here,
                    onChanged: (SyncSide side) => setState(
                      () => _choices = <String, SyncSide>{
                        ..._choices,
                        row.localKey: side,
                      },
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Attendance rows are keyed on their subject's uuid, and a row that only the
/// account holds names a subject this device may not have yet — so the account
/// side has to be able to supply the name too.
Map<String, String> _namesByUuid(SyncMergePlan plan, List<Subject> subjects) {
  return <String, String>{
    for (final Subject s in subjects)
      if (s.uuid != null) s.uuid!: s.name,
    for (final List<SyncMergeRow> rows in <List<SyncMergeRow>>[
      plan.agreed,
      plan.onlyHere,
      plan.onlyThere,
      plan.differing,
    ])
      for (final SyncMergeRow row in rows)
        if (row.kind == SyncKind.subject && row.fields['name'] is String)
          row.localKey: row.fields['name']! as String,
  };
}

/// What to head a contested row with. Only attendance is keyed on a subject,
/// so everything else names itself.
String _titleOf(SyncMergeRow row, Map<String, String> names) {
  return switch (row.kind) {
    SyncKind.settings => 'Semester and teaching day',
    SyncKind.category => 'Class type · ${row.localKey}',
    SyncKind.room => 'Room · ${row.localKey}',
    SyncKind.tag => 'Label · ${row.localKey}',
    SyncKind.holiday => 'Holiday · ${_day(row.localKey)}',
    SyncKind.subject => names[row.localKey] ?? 'A course',
    SyncKind.slot || SyncKind.extraClass =>
      names[row.fields['subject'] as String? ?? ''] ?? 'A class',
    SyncKind.attendance =>
      names[row.localKey.split(':').first] ?? 'A course',
  };
}

String _day(String dateKey) {
  final int? key = int.tryParse(dateKey);
  return key == null ? dateKey : Dates.formatDayMonth(Dates.fromKey(key));
}

class _Summary extends StatelessWidget {
  const _Summary({required this.plan, required this.fromAccount});

  final SyncMergePlan plan;
  final int fromAccount;

  @override
  Widget build(BuildContext context) {
    final int up = plan.onlyHere.length + plan.differing.length - fromAccount;
    final int down = plan.onlyThere.length + fromAccount;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Line(
            icon: Icons.arrow_upward,
            text: '${Words.plural(up, 'row')} sent up to your account',
          ),
          const SizedBox(height: AppSpacing.sm),
          _Line(
            icon: Icons.arrow_downward,
            text: '${Words.plural(down, 'row')} brought down to this device',
          ),
          if (plan.agreed.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            _Line(
              icon: Icons.check,
              text: '${Words.plural(plan.agreed.length, 'row')} already match',
            ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Row(
      children: <Widget>[
        Icon(icon, size: 17, color: p.textTertiary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.row,
    required this.name,
    required this.side,
    required this.onChanged,
  });

  final SyncMergeRow row;
  final String name;
  final SyncSide side;
  final ValueChanged<SyncSide> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(name, style: Theme.of(context).textTheme.titleSmall),
            if (row.kind == SyncKind.attendance)
              Text(
                _when(row.localKey),
                style: TextStyle(fontSize: 12, color: p.textTertiary),
              ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: _Choice(
                    label: 'This device',
                    value: _describe(row, SyncSide.here),
                    selected: side == SyncSide.here,
                    onTap: () => onChanged(SyncSide.here),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _Choice(
                    label: 'Your account',
                    value: _describe(row, SyncSide.there),
                    selected: side == SyncSide.there,
                    onTap: () => onChanged(SyncSide.there),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color accent = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(
            color: selected ? accent : p.outlineSoft,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? accent : p.textTertiary,
              ),
            ),
            const SizedBox(height: 2),
            Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// What one side of a row says, short enough to sit in a chip.
String _describe(SyncMergeRow row, SyncSide side) {
  if (side == SyncSide.there && (row.remote?.deleted ?? false)) {
    return 'Deleted';
  }
  final Map<String, Object?>? fields = side == SyncSide.here
      ? row.local?.fields
      : row.remote?.fields;
  if (fields == null) return '—';

  switch (row.kind) {
    case SyncKind.subject:
      return (fields['name'] as String?) ?? '—';
    case SyncKind.holiday:
      return (fields['name'] as String?) ?? '—';
    case SyncKind.settings:
      final Object? start = fields['semesterStart'];
      return start == null ? 'Not set' : 'Term from ${_day('$start')}';
    case SyncKind.category:
      return '${fields['defaultMinutes'] ?? '—'} min';
    case SyncKind.room:
    case SyncKind.tag:
      return 'Position ${fields['position'] ?? 0}';
    case SyncKind.slot:
    case SyncKind.extraClass:
      final Object? from = fields['startMinutes'];
      return from is int ? Clock.format(from) : '—';
    case SyncKind.attendance:
      break;
  }

  final AttendanceStatus? status =
      AttendanceStatus.fromName(fields['status'] as String?);
  final Object? weight = fields['weight'];
  final String label = status?.label ?? '—';
  return weight is int && weight != 1 ? '$label ×$weight' : label;
}

String _when(String localKey) {
  final List<String> parts = localKey.split(':');
  if (parts.length != 3) return '';
  final int? dateKey = int.tryParse(parts[1]);
  final int? start = int.tryParse(parts[2]);
  if (dateKey == null || start == null) return '';
  return '${Dates.formatDayMonth(Dates.fromKey(dateKey))} · '
      '${Clock.format(start)}';
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.palette.textTertiary,
            height: 1.5,
          ),
    );
  }
}
