import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/words.dart';
import '../../data/models/subject.dart';
import '../../domain/attendance_stats.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/attendance_log_screen.dart';
import '../subjects/class_editor_sheets.dart';
import 'simulate_sheet.dart';

/// The sheet a subject card opens: its figures, its verdict and what can
/// be done about it.
Future<void> showSubjectDetail(
  BuildContext context,
  SubjectStats stats,
) async {
  await showAppSheet<void>(
    context: context,
    title: stats.subject.name,
    child: _SubjectDetail(stats: stats),
  );
}

class _SubjectDetail extends ConsumerWidget {
  const _SubjectDetail({required this.stats});

  final SubjectStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(context),
        const SizedBox(height: AppSpacing.xl),
        ..._figures(context),
        const SizedBox(height: AppSpacing.xl),
        ..._verdict(context),
        const SizedBox(height: AppSpacing.xl),
        ..._actions(context, ref),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final AppPalette p = context.palette;
    final Subject subject = stats.subject;
    final String meta = <String>[
      if (subject.code != null && subject.code!.isNotEmpty) subject.code!,
      if (subject.teacher != null && subject.teacher!.isNotEmpty)
        subject.teacher!,
    ].join(' · ');
    return Row(
      children: <Widget>[
        SubjectAvatar(
            initials: subject.initials, color: subject.color, size: 48),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (meta.isNotEmpty) ...<Widget>[
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                      color: p.textTertiary, size: AppType.labelSmall),
                ),
                const SizedBox(height: 5),
              ],
              Text(
                'Target ${Words.percent(stats.target * 100)}',
                style: TextStyle(
                  fontSize: AppType.bodySmall,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static Widget _row(List<_MetricTile> tiles) => Row(
        children: <Widget>[
          for (final (int i, _MetricTile tile) in tiles.indexed) ...<Widget>[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            Expanded(child: tile),
          ],
        ],
      );

  List<Widget> _figures(BuildContext context) {
    final AppPalette p = context.palette;
    return <Widget>[
      _row(<_MetricTile>[
        _MetricTile(
          label: 'Attended',
          value: '${stats.attended}',
          color: p.present,
        ),
        _MetricTile(
          label: 'Missed',
          value: '${stats.held - stats.attended}',
          color: p.absent,
        ),
        _MetricTile(
          label: 'Cancelled',
          value: '${stats.cancelledTotal}',
          color: p.cancelled,
        ),
      ]),
      const SizedBox(height: AppSpacing.md),
      _row(<_MetricTile>[
        _MetricTile(
          label: 'Can skip',
          value: stats.meetsTarget ? '${stats.canSkip}' : '0',
          color: p.accent,
        ),
        _MetricTile(
          label: 'Must attend',
          // More than is left in the term, once the target is gone.
          value: stats.isUnrecoverable ? '—' : '${stats.needToAttend}',
          color: p.warning,
        ),
        _MetricTile(
          label: 'Left in term',
          value: '${stats.remainingPlanned}',
          color: p.cyan,
        ),
      ]),
    ];
  }

  List<Widget> _verdict(BuildContext context) {
    final AppPalette p = context.palette;
    return <Widget>[
      SurfaceCard(
        elevated: false,
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              stats.meetsTarget
                  ? Icons.check_circle_outline_rounded
                  : Icons.error_outline_rounded,
              size: 17,
              color: healthColor(stats.health, p),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                stats.headline,
                style: TextStyle(
                  fontSize: AppType.bodyMedium,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
      if (stats.remainingPlanned > 0) ...<Widget>[
        const SizedBox(height: AppSpacing.md),
        Text(
          'Attending every remaining class would put you at '
          '${Words.percent(stats.maxAchievableRatio * 100)}.',
          style: TextStyle(
              fontSize: AppType.labelLarge, height: 1.4, color: p.textTertiary),
        ),
      ],
    ];
  }

  List<Widget> _actions(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    final Subject subject = stats.subject;
    return <Widget>[
      OutlinedButton.icon(
        onPressed: () => showSimulateSheet(context, stats),
        icon: const Icon(Icons.tune_rounded, size: 18),
        label: const Text('Simulate'),
      ),
      const SizedBox(height: AppSpacing.sm),
      Text(
        'See where your percentage would land if you attend or miss the '
        'classes ahead.',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: AppType.labelLarge, height: 1.4, color: p.textTertiary),
      ),
      const SizedBox(height: AppSpacing.lg),
      OutlinedButton.icon(
        onPressed: () async {
          // Same ordering as Edit below: push on top first, because popping
          // this sheet would unmount the context being navigated from.
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'attendance_log'),
              builder: (BuildContext context) =>
                  AttendanceLogScreen(subject: subject),
            ),
          );
          if (context.mounted) Navigator.of(context).pop();
        },
        icon: const Icon(Icons.history_rounded, size: 18),
        label: const Text('Attendance log'),
      ),
      const SizedBox(height: AppSpacing.md),
      Row(
        children: <Widget>[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                // Open the editor on top first — popping this sheet before
                // awaiting would unmount the context we need.
                await showSubjectEditor(context, subject: subject);
                if (context.mounted) Navigator.of(context).pop();
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit'),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _confirmDelete(context, ref, subject),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.absent,
                backgroundColor: p.absent.withValues(alpha: 0.1),
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Delete'),
            ),
          ),
        ],
      ),
    ];
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Subject subject,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Delete ${subject.name}?'),
        content: const Text(
          'This also removes its classes and all attendance history.',
          style: TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: context.palette.absent,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final int? id = subject.id;
    if (id != null) {
      final ActionCore core = ref.read(actionCoreProvider);
      final SubjectActions subjects = ref.read(subjectActionsProvider);
      await subjects.deleteSubject(id);
      showUndoSnack(messenger, core, '${subject.name} deleted');
    }
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      decoration: BoxDecoration(
        // Not surfaceHigh: in light that is the sheet's own colour, and the
        // tiles only ever sit on the subject sheet.
        color: p.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: AppType.headlineLarge,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: color,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.captionMedium,
              height: 1,
              fontWeight: FontWeight.w600,
              color: p.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
