import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/words.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_stats.dart';
import '../../domain/tag_stats.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'out_of_term_notice.dart';
import 'stats_page_list.dart';
import 'subject_detail_sheet.dart';
import 'tag_card.dart';

/// Where you stand, and how much room you have left.
class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  static const double _pad = StatsPageList.sidePad;

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
    final OutOfTermMarks strays = ref.watch(outOfTermMarksProvider);

    return StatsPageList(
      slivers: <Widget>[
        // Before the empty state: "no data yet" over a term of marks dated
        // outside the term is the confusion this exists to end.
        if (!strays.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 16),
            sliver: SliverToBoxAdapter(
              child: OutOfTermNotice(marks: strays, settings: settings),
            ),
          ),
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
                  onTap: () => showSubjectDetail(context, subjectStats),
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
                  return TagCard(
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
                        fontSize: AppType.bodyMedium,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      stats.hasData
                          ? '${stats.attended} of ${stats.held} attended'
                          : 'Nothing marked yet',
                      style: monoStyle(
                          color: p.textTertiary, size: AppType.captionMedium),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                stats.hasData ? Words.percent(stats.percent) : '—',
                style: TextStyle(
                  fontSize: AppType.headingLarge,
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
                fontSize: AppType.captionLarge,
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
