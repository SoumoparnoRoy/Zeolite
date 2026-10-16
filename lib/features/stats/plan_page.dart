import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/class_session.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_stats.dart';
import '../../domain/term_outlook.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'stats_page_list.dart';
import 'stats_view.dart';

/// The rest of the term: how many classes each subject can still lose, and
/// the classes ahead that it cannot.
class PlanPage extends ConsumerWidget {
  const PlanPage({super.key});

  static const double _pad = StatsPageList.sidePad;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<TimetableData> loaded = ref.watch(timetableProvider);
    final OverallStats stats = ref.watch(statsProvider);
    final TermPlan plan = ref.watch(termPlanProvider);
    final List<ClassSession> ahead =
        ref.watch(statsViewProvider) == StatsView.plan
            ? ref.watch(classesAheadProvider)
            : const <ClassSession>[];
    // Watched whole, not just its value: without settings there are no term
    // dates, and "Set term dates" is the wrong thing to tell someone whose
    // settings are still loading or failed to.
    final AsyncValue<AppSettings> loadedSettings = ref.watch(settingsProvider);
    final AppSettings settings = loadedSettings.value ?? const AppSettings();

    final Widget? empty = !loaded.hasValue
        ? (loaded.hasError
            ? LoadFailed(onRetry: () => ref.invalidate(timetableProvider))
            : const SizedBox.shrink())
        : !loadedSettings.hasValue
            ? (loadedSettings.hasError
                ? LoadFailed(onRetry: () => ref.invalidate(settingsProvider))
                : const SizedBox.shrink())
            : stats.subjects.isEmpty
                ? const EmptyState(
                    icon: Icons.event_note_outlined,
                    title: 'Nothing to plan yet',
                    message: 'Add subjects and their classes — what you can '
                        'still miss this term appears here.',
                  )
                : plan.isEmpty
                    ? const EmptyState(
                        icon: Icons.event_note_outlined,
                        title: 'Set term dates to plan',
                        message:
                            "Add the term's start and end in Settings, or a "
                            'term total for each subject, to see how many classes '
                            'you can still miss.',
                      )
                    : null;

    if (empty != null) {
      return StatsPageList(
        slivers: <Widget>[
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 40, bottom: 80),
              child: empty,
            ),
          ),
        ],
      );
    }

    final List<_Week> weeks = _Week.group(ahead);
    // Without an end date only subjects with their own term total can be
    // planned; the rest are left out, and the page says so.
    final bool dated = settings.termEnd != null;
    final int leftOut = dated
        ? 0
        : stats.subjects
            .where((SubjectStats s) => s.subject.expectedTotal == null)
            .length;
    return StatsPageList(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 24),
          sliver: SliverToBoxAdapter(
            child: _TermCard(plan: plan, leftOut: leftOut),
          ),
        ),
        const SliverPadding(
          padding: EdgeInsets.fromLTRB(_pad, 0, _pad, 0),
          sliver: SliverToBoxAdapter(child: SectionHeader('By subject')),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 24),
          sliver: SliverList.separated(
            itemCount: plan.subjects.length,
            separatorBuilder: (_, __) => const SizedBox(height: 11),
            itemBuilder: (BuildContext context, int index) =>
                _SubjectPlanCard(outlook: plan.subjects[index]),
          ),
        ),
        if (!dated)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 88),
            sliver: SliverToBoxAdapter(
              child: Text(
                "Add the term's end date in Settings to list the classes "
                'ahead.',
                style: TextStyle(
                  fontSize: AppType.captionLarge,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: context.palette.textTertiary,
                ),
              ),
            ),
          )
        else if (weeks.isEmpty)
          const SliverToBoxAdapter(child: SizedBox(height: 64)),
        for (final _Week week in weeks) ...<Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 0),
            sliver: SliverToBoxAdapter(child: SectionHeader(week.title)),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
                _pad, 0, _pad, week == weeks.last ? 88 : 20),
            sliver: SliverToBoxAdapter(
              child: SurfaceCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: <Widget>[
                    for (final ClassSession session in week.sessions)
                      _AheadRow(
                        session: session,
                        outlook: plan.forSubject(session.subject.id),
                        use24Hour: settings.use24HourTime,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The term as a whole, and the one place the budget is told apart from
/// "You can skip N more".
class _TermCard extends StatelessWidget {
  const _TermCard({required this.plan, required this.leftOut});

  final TermPlan plan;

  /// Subjects the plan could not include, for want of a term total.
  final int leftOut;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            // Classes, even where a lab counts as two periods: a total that
            // adds both is not a count of either, and the headline above
            // already says classes.
            '${Words.plural(plan.remaining, 'class', 'classes')} left this term',
            style: TextStyle(
              fontSize: AppType.bodyMedium,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          _Figure(
            label: 'Attend every one and you finish on',
            value: Words.attendance(plan.bestPercent),
          ),
          const SizedBox(height: 8),
          _Figure(
            label: 'Use every skip budget and you finish on',
            value: Words.attendance(plan.spentPercent),
          ),
          const SizedBox(height: 12),
          Text(
            'A skip budget counts the classes still to come. '
            '"You can skip N more" on Overview is how many you could miss in '
            'a row from today, so the two rarely match.',
            style: TextStyle(
              fontSize: AppType.captionLarge,
              height: 1.4,
              fontWeight: FontWeight.w500,
              color: p.textTertiary,
            ),
          ),
          if (leftOut > 0) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '${Words.count(leftOut)} ${Words.noun(leftOut, 'subject')} '
              'without a term total ${leftOut == 1 ? 'is' : 'are'} not '
              'counted here.',
              style: TextStyle(
                fontSize: AppType.captionLarge,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppType.captionLarge,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: p.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          style: monoStyle(
            color: p.textPrimary,
            size: AppType.bodyMedium,
            weight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _SubjectPlanCard extends StatelessWidget {
  const _SubjectPlanCard({required this.outlook});

  final TermOutlook outlook;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Subject subject = outlook.stats.subject;
    final String left = Words.plural(
      outlook.remaining,
      outlook.stats.weighted ? 'period' : 'class',
      outlook.stats.weighted ? 'periods' : 'classes',
    );
    final String best = Words.attendance(outlook.bestRatio * 100);
    final String range = !outlook.reachable || outlook.budget == 0
        ? 'Best finish $best'
        : 'Finishes between ${Words.attendance(outlook.spentRatio * 100)} and '
            '$best';

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                // The target is the subject's own, which can differ from the
                // overall one; a finish of 66% only reads right beside it.
                Text(
                  '$left left · target '
                  '${Words.percent(outlook.stats.target * 100)}',
                  style: monoStyle(
                      color: p.textTertiary, size: AppType.captionMedium),
                ),
                const SizedBox(height: 6),
                Text(
                  range,
                  style: TextStyle(
                    fontSize: AppType.captionLarge,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: p.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  outlook.line,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: AppType.captionLarge,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: outlookColor(outlook, p),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One class ahead. Only the ones that cannot be spared say so: a subject
/// with room would otherwise repeat its budget on every row.
class _AheadRow extends StatelessWidget {
  const _AheadRow({
    required this.session,
    required this.outlook,
    required this.use24Hour,
  });

  final ClassSession session;
  final TermOutlook? outlook;
  final bool use24Hour;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final AttendanceHealth? health = outlook?.health;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 92 * AppScale.of(MediaQuery.sizeOf(context)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  Dates.relativeLabel(session.date),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.captionMedium,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: p.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  Clock.format(session.startMinutes, use24Hour: use24Hour),
                  maxLines: 1,
                  softWrap: false,
                  style: monoStyle(
                      color: p.textTertiary, size: AppType.microLarge),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: session.subject.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              session.subject.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.captionLarge,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
          ),
          if (health == AttendanceHealth.tight) ...<Widget>[
            const SizedBox(width: 8),
            Pill(label: 'Attend', color: healthColor(health!, p)),
          ] else if (health == AttendanceHealth.lost) ...<Widget>[
            const SizedBox(width: 8),
            Pill(label: 'Out of reach', color: healthColor(health!, p)),
          ],
        ],
      ),
    );
  }
}

/// A Monday-to-Sunday run of [ClassSession]s, titled for how far off it is.
class _Week {
  _Week(this.monday, this.sessions);

  final DateTime monday;
  final List<ClassSession> sessions;

  String get title {
    final int weeksOff =
        Dates.daysBetween(Dates.startOfWeek(Dates.today()), monday) ~/ 7;
    if (weeksOff == 0) return 'This week';
    if (weeksOff == 1) return 'Next week';
    return Dates.formatWeekRange(monday, Dates.addDays(monday, 6));
  }

  static List<_Week> group(List<ClassSession> sessions) {
    final List<_Week> weeks = <_Week>[];
    for (final ClassSession session in sessions) {
      final DateTime monday = Dates.startOfWeek(session.date);
      if (weeks.isEmpty || !Dates.isSameDay(weeks.last.monday, monday)) {
        weeks.add(_Week(monday, <ClassSession>[]));
      }
      weeks.last.sessions.add(session);
    }
    return weeks;
  }
}
