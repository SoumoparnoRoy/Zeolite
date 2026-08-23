import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_stats.dart';
import '../../domain/tag_stats.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/attendance_log_screen.dart';
import '../subjects/class_editor_sheets.dart';

/// Attendance overview: where you stand, and how much room you have left.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  static const double _pad = 20;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final OverallStats stats = ref.watch(statsProvider);
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    // Tags with nothing on them are dropped here rather than in the provider:
    // Settings still needs to list an unused tag, this screen does not.
    final List<TagBreakdown> tagged = ref
        .watch(tagBreakdownsProvider)
        .where((TagBreakdown b) => !b.isEmpty)
        .toList();
    final bool hasTags = tagged.isNotEmpty;

    return GradientScaffold(
      headerGap: 18,
      header: _OverallHeader(stats: stats, settings: settings),
      slivers: <Widget>[
        if (stats.subjects.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(top: 40, bottom: 80),
              child: EmptyState(
                icon: Icons.insights_outlined,
                title: 'No data yet',
                message: 'Add subjects and mark a few classes — your '
                    'percentages and skip allowance appear here.',
              ),
            ),
          )
        else ...<Widget>[
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(_pad, 0, _pad, 0),
            sliver: SliverToBoxAdapter(child: SectionHeader('By subject')),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(_pad, 0, _pad, hasTags ? 24 : 88),
            sliver: SliverList.separated(
              itemCount: stats.subjects.length,
              separatorBuilder: (_, __) => const SizedBox(height: 11),
              itemBuilder: (BuildContext context, int index) {
                final SubjectStats subjectStats = stats.subjects[index];
                return _SubjectStatsCard(
                  stats: subjectStats,
                  onTap: () => _showSubjectDetail(context, ref, subjectStats),
                );
              },
            ),
          ),

          // Only once something is actually tagged. An install that never
          // opens the Tags setting never learns this section exists, which
          // is the point — the screen it replaces was already full.
          if (hasTags) ...<Widget>[
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(_pad, 0, _pad, 0),
              sliver: SliverToBoxAdapter(child: SectionHeader('By tag')),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 88),
              sliver: SliverList.separated(
                itemCount: tagged.length,
                separatorBuilder: (_, __) => const SizedBox(height: 11),
                itemBuilder: (BuildContext context, int index) {
                  return _TagCard(
                    breakdown: tagged[index],
                    use24Hour: settings.use24HourTime,
                  );
                },
              ),
            ),
          ],
        ],
      ],
    );
  }

  Future<void> _showSubjectDetail(
    BuildContext context,
    WidgetRef ref,
    SubjectStats stats,
  ) async {
    await showAppSheet<void>(
      context: context,
      title: stats.subject.name,
      child: _SubjectDetail(stats: stats),
    );
  }
}

/// The term's percentage, set in type at the size the ring used to be. The
/// ring spent its whole area on one number; the three counts it hid now sit
/// beside it as a legend.
class _OverallHeader extends StatelessWidget {
  const _OverallHeader({required this.stats, required this.settings});

  final OverallStats stats;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: HeaderEyebrow('Attendance · this term'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              HeaderNumber(
                stats.hasData ? '${stats.percent.round()}' : '—',
                size: 60,
                unit: stats.hasData ? '%' : '',
              ),
              const SizedBox(width: 16),
              // Capped, not just Expanded: on a wide column a label/value pair
              // stretched to the full width leaves the count stranded half a
              // screen from the word it belongs to.
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 190),
                  child: Column(
                    children: <Widget>[
                      _LegendLine(label: 'Attended', value: stats.present),
                      const SizedBox(height: 7),
                      _LegendLine(label: 'Missed', value: stats.absent),
                      const SizedBox(height: 7),
                      _LegendLine(
                        label: 'Cancelled',
                        value: stats.cancelled,
                        // Cancelled counts towards neither side of the
                        // percentage, so its line reads quieter than the two
                        // that do.
                        dimmed: true,
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
        if (settings.hasSemester) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: HeaderMeter(value: settings.semesterProgress),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              'Semester ${(settings.semesterProgress * 100).round()}% done · '
              '${Words.plural(settings.daysLeftInSemester, 'day')} left',
              style: TextStyle(
                fontSize: 10.5,
                height: 1,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _LegendLine extends StatelessWidget {
  const _LegendLine({
    required this.label,
    required this.value,
    this.dimmed = false,
  });

  final String label;
  final int value;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        // The count is the point of the line, so the label is the half that
        // gives way when the system font is scaled up.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: dimmed ? 0.6 : 0.85),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$value',
          style: TextStyle(
            fontFamily: AppFonts.mono,
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w700,
            color: Colors.white.withValues(alpha: dimmed ? 0.8 : 1),
          ),
        ),
      ],
    );
  }
}

class _SubjectStatsCard extends StatelessWidget {
  const _SubjectStatsCard({required this.stats, required this.onTap});

  final SubjectStats stats;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Subject subject = stats.subject;
    final Color tint = healthColor(stats.health, p);

    return SurfaceCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              SubjectAvatar(
                initials: subject.initials,
                color: subject.color,
                size: 34,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      subject.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      stats.hasData
                          ? '${stats.present} of ${stats.held} attended'
                          : 'nothing marked yet',
                      style: monoStyle(color: p.textTertiary, size: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                stats.hasData ? '${stats.percent.toStringAsFixed(0)}%' : '—',
                style: TextStyle(
                  fontSize: 16,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  color: stats.hasData ? tint : p.textFaint,
                ),
              ),
            ],
          ),
          if (stats.hasData) ...<Widget>[
            const SizedBox(height: 11),
            TargetBar(
              value: stats.ratio,
              color: healthFill(stats.health, p),
              target: stats.target,
            ),
            const SizedBox(height: 5),
            Text(
              stats.headline,
              maxLines: 2,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
                // Calm by default. The colour is spent only on the subjects
                // that actually need attention, so a screen of healthy ones
                // reads as one quiet grey column.
                color: stats.meetsTarget ? p.textTertiary : tint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubjectDetail extends ConsumerWidget {
  const _SubjectDetail({required this.stats});

  final SubjectStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    final Subject subject = stats.subject;
    final String meta = <String>[
      if (subject.code != null && subject.code!.isNotEmpty) subject.code!,
      if (subject.teacher != null && subject.teacher!.isNotEmpty)
        subject.teacher!,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            SubjectAvatar(
              initials: subject.initials,
              color: subject.color,
              size: 48,
            ),
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
                      style: monoStyle(color: p.textTertiary, size: 11),
                    ),
                    const SizedBox(height: 5),
                  ],
                  Text(
                    'Target ${(stats.target * 100).round()}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        Row(
          children: <Widget>[
            Expanded(
              child: _MetricTile(
                label: 'Attended',
                value: '${stats.present}',
                color: p.present,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _MetricTile(
                label: 'Missed',
                value: '${stats.absent}',
                color: p.absent,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _MetricTile(
                label: 'Cancelled',
                value: '${stats.cancelled}',
                color: p.cancelled,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: <Widget>[
            Expanded(
              child: _MetricTile(
                label: 'Can skip',
                value: stats.meetsTarget ? '${stats.canSkip}' : '0',
                color: p.accent,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _MetricTile(
                label: 'Must attend',
                value: '${stats.needToAttend}',
                color: p.warning,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _MetricTile(
                label: 'Left in term',
                value: '${stats.remainingPlanned}',
                color: p.cyan,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        SurfaceCard(
          elevated: false,
          color: p.surfaceHigh,
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
                    fontSize: 12.5,
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
            '${(stats.maxAchievableRatio * 100).toStringAsFixed(0)}%.',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: p.textTertiary,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        OutlinedButton.icon(
          onPressed: () async {
            // Same ordering as Edit below: push on top first, because popping
            // this sheet would unmount the context being navigated from.
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
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
                  await showSubjectEditor(context, ref, subject: subject);
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
      ],
    );
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
      final TimetableActions actions = ref.read(actionsProvider);
      await actions.deleteSubject(id);
      showUndoSnack(messenger, actions, 'Deleted ${subject.name}');
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
        color: p.surfaceHigh,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 19,
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
              fontSize: 10,
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

/// One tag on the stats screen: what it is, how it is split, and how far it
/// reaches across subjects.
///
/// No percentage, on purpose. A tag has no target behind it, so a figure like
/// "Proxy 62%" would read as a score against something that does not exist.
/// The classes themselves are one tap away rather than listed inline, which is
/// what keeps a heavily-used tag from burying the subjects above it.
class _TagCard extends StatelessWidget {
  const _TagCard({required this.breakdown, required this.use24Hour});

  final TagBreakdown breakdown;
  final bool use24Hour;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color accent = p.cyan;
    return SurfaceCard(
      onTap: () => _showDetail(context),
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: p.isDark ? 0.18 : 0.14),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              Icons.sell_outlined,
              size: 16,
              color: AppColors.inkOn(accent, p),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  breakdown.tag.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  breakdown.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: p.textTertiary, size: 10),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${breakdown.total}',
            style: TextStyle(
              fontSize: 16,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: AppColors.inkOn(accent, p),
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, size: 18, color: p.textFaint),
        ],
      ),
    );
  }

  Future<void> _showDetail(BuildContext context) {
    return showAppSheet<void>(
      context: context,
      title: breakdown.tag.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            breakdown.subjectCount == 1
                ? '${breakdown.countLabel} in one subject · ${breakdown.summary}'
                : '${breakdown.countLabel} across ${breakdown.subjectCount} '
                    'subjects · ${breakdown.summary}',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: context.palette.textTertiary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          for (final TaggedMark mark in breakdown.marks)
            _TaggedMarkRow(mark: mark, use24Hour: use24Hour),
        ],
      ),
    );
  }
}

class _TaggedMarkRow extends StatelessWidget {
  const _TaggedMarkRow({required this.mark, required this.use24Hour});

  final TaggedMark mark;
  final bool use24Hour;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final AttendanceStatus status = mark.status;
    // A subject can only be missing on a hand-edited import; showing the row
    // anyway keeps the count above honest instead of silently disagreeing.
    final Subject? subject = mark.subject;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          SubjectAvatar(
            initials: subject?.initials ?? '?',
            color: subject?.color ?? p.textFaint,
            size: 30,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  subject?.name ?? 'Deleted subject',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${Dates.formatDayMonth(mark.record.date)} · '
                  '${Clock.format(mark.record.startMinutes, use24Hour: use24Hour)}',
                  style: monoStyle(color: p.textTertiary, size: 10),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Pill(label: status.label, color: status.colorIn(p)),
        ],
      ),
    );
  }
}
