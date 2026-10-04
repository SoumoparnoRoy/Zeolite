import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/words.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_stats.dart';
import '../../state/providers.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/kept_alive.dart';
import '../../widgets/pager_handoff.dart';
import 'counts_page.dart';
import 'overview_page.dart';
import 'stats_page_list.dart';
import 'stats_view.dart';

/// Attendance in two views under one header: where you stand, and the three
/// counts behind it for anyone who keeps them by hand.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  late final PageController _views =
      PageController(initialPage: ref.read(statsViewProvider).index);

  @override
  void initState() {
    super.initState();
    ref.listenManual<StatsView>(statsViewProvider,
        (StatsView? _, StatsView view) {
      if (!_views.hasClients || _views.page?.round() == view.index) return;
      unawaited(_views.animateToPage(
        view.index,
        duration: AppMotion.pageSlide,
        curve: AppMotion.pageCurve,
      ));
    });
  }

  @override
  void dispose() {
    _views.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    final StatsView view = StatsView.values[page];
    ref.read(statsViewProvider.notifier).show(view);
    unawaited(ref
        .read(analyticsProvider)
        .screen(view == StatsView.counts ? 'counts' : 'stats'));
  }

  @override
  Widget build(BuildContext context) {
    final OverallStats stats = ref.watch(statsProvider);
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();

    return PagerHandoff(
      controller: _views,
      child: GradientScaffold(
        headerGap: 18,
        header: OverallStatsHeader(stats: stats, settings: settings),
        aboveThePages: Padding(
          padding: const EdgeInsets.fromLTRB(
            StatsPageList.sidePad,
            0,
            StatsPageList.sidePad,
            16,
          ),
          child: StatsViewSwitch(
            current: ref.watch(statsViewProvider),
            onSelect: ref.read(statsViewProvider.notifier).show,
          ),
        ),
        pages: PageView(
          controller: _views,
          physics: const HandoffPagePhysics(),
          onPageChanged: _onPageChanged,
          children: const <Widget>[
            KeptAlive(child: OverviewPage()),
            KeptAlive(child: CountsPage()),
          ],
        ),
      ),
    );
  }
}

/// The term's percentage, set in type at the size the ring used to be. The
/// ring spent its whole area on one number; the three counts it hid now sit
/// beside it as a legend.
class OverallStatsHeader extends StatelessWidget {
  const OverallStatsHeader({
    super.key,
    required this.stats,
    required this.settings,
  });

  final OverallStats stats;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final String toCome =
        Words.plural(stats.expectedTotal - stats.held, 'class', 'classes');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: HeaderEyebrow('Attendance · this term'),
        ),
        // A dash at this size reads as a bar, and three zeros say nothing.
        if (!stats.hasData)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 7, 20, 0),
            child: HeaderTitle('Nothing marked yet'),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                HeaderNumber('${stats.percent.round()}',
                    size: AppType.figureXl),
                const SizedBox(width: 16),
                // Capped, not just Expanded: on a wide column a label/value
                // pair stretched to the full width leaves the count stranded
                // half a screen from the word it belongs to.
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 190),
                    child: Column(
                      children: <Widget>[
                        _LegendLine(label: 'Attended', value: stats.attended),
                        const SizedBox(height: 7),
                        _LegendLine(
                          label: 'Missed',
                          value: stats.held - stats.attended,
                        ),
                        const SizedBox(height: 7),
                        _LegendLine(
                          label: 'Cancelled',
                          value: stats.cancelled,
                          // Cancelled usually leaves the percentage alone, so
                          // its line reads quieter than the two that always
                          // move it.
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
        // Shown so a student cross-checking against their portal does not
        // think one of the two is broken; dropped once they agree.
        if (stats.termPercent != null && stats.expectedTotal > stats.held)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              'Your portal will say ${Words.percent(stats.termPercent!)} — it counts '
              'the $toCome still to come as missed.',
              style: TextStyle(
                fontSize: AppType.captionLarge,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
          ),
        if (settings.hasTerm) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: HeaderMeter(value: settings.termProgress),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              'Term ${Words.percent(settings.termProgress * 100)} done · '
              '${Words.plural(settings.daysLeftInTerm, 'day')} left',
              style: TextStyle(
                fontSize: AppType.captionLarge,
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
              fontSize: AppType.labelSmall,
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
            fontSize: AppType.labelSmall,
            height: 1,
            fontWeight: FontWeight.w700,
            color: Colors.white.withValues(alpha: dimmed ? 0.8 : 1),
          ),
        ),
      ],
    );
  }
}
