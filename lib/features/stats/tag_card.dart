import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../domain/tag_stats.dart';
import '../../widgets/common.dart';

/// One tag on the stats screen: what it is, how it is split, and how far it
/// reaches across subjects.
///
/// No percentage, on purpose. A tag has no target behind it, so a figure like
/// "Proxy 62%" would read as a score against something that does not exist.
/// The classes themselves are one tap away rather than listed inline, which is
/// what keeps a heavily-used tag from burying the subjects above it.
class TagCard extends StatelessWidget {
  const TagCard({super.key, required this.breakdown, required this.use24Hour});

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
                    fontSize: AppType.bodyMedium,
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
                  style: monoStyle(
                      color: p.textTertiary, size: AppType.captionMedium),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${breakdown.total}',
            style: TextStyle(
              fontSize: AppType.headingLarge,
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
              fontSize: AppType.bodySmall,
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
                    fontSize: AppType.bodyMedium,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${Dates.formatDayMonth(mark.record.date)} · '
                  '${AttendanceRecord.startLabel(mark.record.startMinutes, use24Hour: use24Hour)}',
                  style: monoStyle(
                      color: p.textTertiary, size: AppType.captionMedium),
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
