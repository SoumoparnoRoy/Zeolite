import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/class_session.dart';
import '../../data/models/holiday.dart';
import '../../data/models/tag.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_stats.dart';
import '../../domain/schedule_engine.dart';
import '../../services/notification_service.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/tag_picker.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/class_editor_sheets.dart';
import '../timetable/week_grid_view.dart';
import 'session_card.dart';
import 'week_strip.dart';

/// Per-day dots for the date strip: how many classes, and whether any of them
/// are still waiting to be marked.
///
/// Computed once per data change rather than on every scroll frame.
final dayMarkersProvider = Provider<Map<int, DayMarker>>((ref) {
  final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
  if (engine == null) return const <int, DayMarker>{};

  final DateTime from = Dates.addDays(Dates.today(), -60);
  final DateTime to = Dates.addDays(Dates.today(), 120);
  final Map<int, List<ClassSession>> byDay =
      engine.sessionsByDayBetween(from, to);

  return <int, DayMarker>{
    for (final MapEntry<int, List<ClassSession>> entry in byDay.entries)
      entry.key: DayMarker(
        count: entry.value.length,
        hasUnmarked: entry.value.any((ClassSession s) => s.needsMarking),
        color: entry.value.first.subject.color,
      ),
  };
});

/// The home screen: what is on today, and one tap to mark each class.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  static const double _pad = 20;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    final DateTime selected = ref.watch(selectedDateProvider);
    final List<ClassSession> sessions = ref.watch(selectedDaySessionsProvider);
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final OverallStats stats = ref.watch(statsProvider);
    final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
    final List<ClassSession> unmarked = ref.watch(unmarkedSessionsProvider);
    final ClassSession? next = ref.watch(nextSessionProvider);
    final TimetableData? data = ref.watch(timetableProvider).value;
    final HomeView view = ref.watch(homeViewProvider);
    final bool isToday = Dates.isSameDay(selected, Dates.today());
    // The grid follows whichever day you were looking at, so switching views
    // does not lose your place and needs no state of its own.
    final DateTime gridWeek = Dates.startOfWeek(selected);

    final Holiday? holiday = engine?.holidayOn(selected);
    final bool outsideSemester = engine?.isOutsideSemester(selected) ?? false;
    final int unmarkedToday =
        sessions.where((ClassSession s) => s.needsMarking).length;

    // Warnings the notification tray is no longer carrying have to surface
    // somewhere, so raise them here once the frame is on screen. Showing it
    // post-frame keeps the dialog out of the build phase, and the announced
    // set makes a rebuild a no-op rather than a second popup.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) _showPendingAlerts(context, ref);
      // Due at most once a day, and a no-op the rest of the time — the check is
      // a date comparison, not an export.
      ref.read(actionsProvider).maybeRunAutoBackup();
    });

    return GradientScaffold(
      onRefresh: () async => ref.invalidate(timetableProvider),
      header: view == HomeView.grid
          ? _GridHeader(
              weekStart: gridWeek,
              count: (engine?.sessionsForWeekOf(gridWeek) ??
                      const <int, List<ClassSession>>{})
                  .values
                  .fold<int>(
                      0, (int sum, List<ClassSession> v) => sum + v.length),
              onShift: (int weeks) =>
                  ref.read(selectedDateProvider.notifier).shiftDays(weeks * 7),
              onToday: () =>
                  ref.read(selectedDateProvider.notifier).goToToday(),
              onToggleView: () => ref.read(homeViewProvider.notifier).toggle(),
            )
          : _DayHeader(
              selected: selected,
              isToday: isToday,
              stats: stats,
              settings: settings,
              markers: ref.watch(dayMarkersProvider),
              onSelectDay: (DateTime date) =>
                  ref.read(selectedDateProvider.notifier).select(date),
              onJumpToToday: () =>
                  ref.read(selectedDateProvider.notifier).goToToday(),
              onToggleView: () => ref.read(homeViewProvider.notifier).toggle(),
            ),
      floatingActionButton: GradientFab(
        label: 'Add class',
        onPressed: () => showAddClassSheet(context, ref, initialDate: selected),
      ),
      slivers: view == HomeView.grid
          ? <Widget>[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 96),
                // The viewport, not what is left to paint — that shrinks as
                // you scroll and would resize the blocks under your finger.
                sliver: SliverLayoutBuilder(
                  builder: (BuildContext context, SliverConstraints c) =>
                      SliverToBoxAdapter(
                    child: WeekGridView(
                      weekStart: gridWeek,
                      availableHeight:
                          c.viewportMainAxisExtent - c.precedingScrollExtent,
                    ),
                  ),
                ),
              ),
            ]
          : <Widget>[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 0),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          isToday
                              ? "Today's classes"
                              : Dates.formatDayMonth(selected),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                            color: p.textPrimary,
                          ),
                        ),
                      ),
                      if (unmarkedToday > 1)
                        InkWell(
                          onTap: () => _markAllPresent(context, ref, sessions),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Text(
                              'All present',
                              style: TextStyle(
                                fontSize: 10.5,
                                height: 1,
                                fontWeight: FontWeight.w700,
                                color: p.accent,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
              if (unmarked.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 12),
                  sliver: SliverToBoxAdapter(
                    child: _UnmarkedBanner(
                      count: unmarked.length,
                      onJump: () => ref
                          .read(selectedDateProvider.notifier)
                          .select(unmarked.first.date),
                    ),
                  ),
                ),
              if (holiday != null)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 12),
                  sliver: SliverToBoxAdapter(
                    child: _NoticeCard(
                      icon: Icons.celebration_rounded,
                      title: holiday.name,
                      message:
                          'Marked as a holiday — no recurring classes today.',
                      color: p.cyan,
                    ),
                  ),
                )
              else if (outsideSemester)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 12),
                  sliver: SliverToBoxAdapter(
                    child: _NoticeCard(
                      icon: Icons.event_busy_rounded,
                      title: 'Outside the semester',
                      message: settings.hasSemester
                          ? 'Your semester runs '
                              '${Dates.formatFull(settings.semesterStart!)} – '
                              '${Dates.formatFull(settings.semesterEnd!)}.'
                          : 'Set your semester dates in Settings.',
                      color: p.textTertiary,
                    ),
                  ),
                ),
              if (sessions.isEmpty && holiday == null && !outsideSemester)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 36),
                    child: EmptyState(
                      icon: Icons.wb_sunny_outlined,
                      title: isToday ? 'Nothing on today' : 'No classes',
                      message: isToday
                          ? 'Enjoy the free day. Add classes from the Timetable tab.'
                          : 'There are no classes scheduled for this day.',
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 96),
                sliver: SliverList.separated(
                  itemCount: sessions.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: SessionCard.gap),
                  itemBuilder: (BuildContext context, int index) {
                    final ClassSession session = sessions[index];
                    final List<Tag> tags = data?.tags ?? const <Tag>[];
                    return SessionCard(
                      session: session,
                      use24Hour: settings.use24HourTime,
                      nextColor: index + 1 < sessions.length
                          ? SessionCard.spineColorOf(
                              sessions[index + 1],
                              context.palette,
                            )
                          : null,
                      categoryName: data?.categoryFor(session.subject)?.name,
                      tagName: data?.tagById(session.record?.tagId)?.name,
                      isNext: next != null &&
                          next.date == session.date &&
                          next.startMinutes == session.startMinutes &&
                          next.subject.id == session.subject.id,
                      onMark: (AttendanceStatus status) =>
                          ref.read(actionsProvider).mark(session, status),
                      onTag: tags.isEmpty
                          ? null
                          : () => _pickTag(context, ref, session, tags),
                      onLongPress: () =>
                          showSessionOptions(context, ref, session),
                    );
                  },
                ),
              ),
            ],
    );
  }

  /// Opens the tag picker for one marked class and writes the result.
  ///
  /// The toggle lives in `setTagAt`, so tapping the tag a class already has
  /// clears it here without this screen knowing the rule.
  Future<void> _pickTag(
    BuildContext context,
    WidgetRef ref,
    ClassSession session,
    List<Tag> tags,
  ) async {
    final int? subjectId = session.subject.id;
    if (subjectId == null) return;
    final int? chosen = await showTagPicker(
      context,
      tags: tags,
      selected: session.record?.tagId,
    );
    if (chosen == null) return;
    await ref.read(actionsProvider).setTagAt(
          subjectId: subjectId,
          date: session.date,
          startMinutes: session.startMinutes,
          tagId: chosen,
        );
  }

  Future<void> _markAllPresent(
    BuildContext context,
    WidgetRef ref,
    List<ClassSession> sessions,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final TimetableActions actions = ref.read(actionsProvider);
    final int count = await actions.markAll(sessions, AttendanceStatus.present);
    if (count == 0) return;
    showUndoSnack(
      messenger,
      actions,
      'Marked $count ${count == 1 ? 'class' : 'classes'} present',
    );
  }

  /// Shows one popup for subjects that have newly fallen into danger while
  /// their system notification is switched off. Subjects that recover are
  /// forgotten, so a later slip warns again.
  void _showPendingAlerts(BuildContext context, WidgetRef ref) {
    final List<SubjectStats> alerts = ref.read(inAppAlertsProvider);
    final AnnouncedAlertsController announced =
        ref.read(announcedAlertsProvider.notifier);
    announced.retainOnly(alerts);

    final List<SubjectStats> pending = announced.pending(alerts);
    if (pending.isEmpty) return;

    // Recorded before awaiting the dialog so a rebuild mid-flight cannot open
    // a second copy of it.
    announced.markAnnounced(pending);
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => _InAppAlertDialog(alerts: pending),
    );
  }
}

/// The gradient block over the day list: which day, the verdict, the week to
/// move around in, and the number the verdict came from.
class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.selected,
    required this.isToday,
    required this.stats,
    required this.settings,
    required this.markers,
    required this.onSelectDay,
    required this.onJumpToToday,
    required this.onToggleView,
  });

  final DateTime selected;
  final bool isToday;
  final OverallStats stats;
  final AppSettings settings;
  final Map<int, DayMarker> markers;
  final ValueChanged<DateTime> onSelectDay;
  final VoidCallback onJumpToToday;
  final VoidCallback onToggleView;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // formatDayMonth already leads with the short weekday, so
                    // it cannot be used after the long one.
                    HeaderEyebrow(
                      '${Dates.weekdayLong(selected)} ${selected.day} '
                      '${kMonthNamesShort[selected.month - 1]}',
                    ),
                    const SizedBox(height: 6),
                    HeaderTitle(stats.verdict),
                  ],
                ),
              ),
              if (!isToday) ...<Widget>[
                const SizedBox(width: 8),
                HeaderIconButton(
                  icon: Icons.today_rounded,
                  tooltip: 'Jump to today',
                  onTap: onJumpToToday,
                ),
              ],
              const SizedBox(width: 8),
              HeaderIconButton(
                icon: Icons.grid_view_rounded,
                tooltip: 'Show the week grid',
                onTap: onToggleView,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        WeekStrip(
          selected: selected,
          markers: markers,
          onSelected: onSelectDay,
        ),
        if (stats.hasData) ...<Widget>[
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                HeaderNumber('${stats.percent.round()}'),
                const SizedBox(width: 14),
                Expanded(
                  child: HeaderCaption(
                    '${stats.attended} attended of ${stats.held} held\n'
                    'target ${settings.targetPercent.toStringAsFixed(0)}%'
                    '${_termTail(settings)}',
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// The second half of the caption, present only when there is a semester to
  /// count down. Without dates the app has nothing to say here, and inventing
  /// a number would be worse than saying nothing.
  String _termTail(AppSettings settings) {
    final DateTime? end = settings.semesterEnd;
    if (end == null) return '';
    final int days = Dates.daysBetween(Dates.today(), end);
    if (days < 0) return ' · term over';
    if (days == 0) return ' · last day of term';
    return ' · ${Words.plural(days, 'day')} of term left';
  }
}

/// The same block over the week grid. No percentage: the grid answers "what
/// does my week look like", and a term-to-date figure is a different question
/// that would only compete with the shape.
class _GridHeader extends StatelessWidget {
  const _GridHeader({
    required this.weekStart,
    required this.count,
    required this.onShift,
    required this.onToday,
    required this.onToggleView,
  });

  final DateTime weekStart;
  final int count;
  final ValueChanged<int> onShift;
  final VoidCallback onToday;
  final VoidCallback onToggleView;

  @override
  Widget build(BuildContext context) {
    final DateTime weekEnd = Dates.addDays(weekStart, 6);
    final bool isCurrent =
        Dates.isSameDay(weekStart, Dates.startOfWeek(Dates.today()));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    HeaderEyebrow(
                      '${weekStart.day} ${kMonthNamesShort[weekStart.month - 1]}'
                      ' – ${weekEnd.day} '
                      '${kMonthNamesLong[weekEnd.month - 1]}',
                    ),
                    const SizedBox(height: 6),
                    HeaderTitle(
                      count == 0
                          ? 'No classes'
                          : '${Words.count(count)} '
                              '${count == 1 ? 'class' : 'classes'}',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              HeaderIconButton(
                icon: Icons.view_agenda_outlined,
                tooltip: 'Show the day',
                onTap: onToggleView,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: HeaderStepper(
            label: isCurrent ? 'This week' : 'Back to this week',
            onBack: () => onShift(-1),
            onForward: () => onShift(1),
            onTapLabel: isCurrent ? null : onToday,
          ),
        ),
      ],
    );
  }
}

/// The in-app stand-in for an attendance notification. Deliberately reuses
/// [NotificationService.dangerMessage] so the wording matches the tray exactly.
class _InAppAlertDialog extends StatelessWidget {
  const _InAppAlertDialog({required this.alerts});

  final List<SubjectStats> alerts;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return AlertDialog(
      icon: Icon(
        // An alarm triangle overstates it — this is a heads-up about a
        // percentage, not an emergency.
        Icons.info_outline_rounded,
        color: p.warning,
        size: 28,
      ),
      title: Text(
        alerts.length == 1
            ? 'Worth a look'
            : '${alerts.length} subjects worth a look',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final SubjectStats s in alerts)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    s.subject.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    NotificationService.dangerMessage(s),
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          Text(
            'Notifications for these are off, so Zeolite is telling you '
            'here instead. Change this in Settings → Notifications.',
            style: TextStyle(
              color: p.textTertiary,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }
}

class _UnmarkedBanner extends StatelessWidget {
  const _UnmarkedBanner({required this.count, required this.onJump});

  final int count;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SurfaceCard(
      color: Color.alphaBlend(p.warning.withValues(alpha: 0.12), p.surface),
      onTap: onJump,
      padding: const EdgeInsets.fromLTRB(13, 11, 11, 11),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 17, color: p.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$count past ${count == 1 ? 'class needs' : 'classes need'} '
              'marking',
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: p.textPrimary,
              ),
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 18, color: p.warning),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 16, color: AppColors.inkOn(color, p)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    color: p.textTertiary,
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
