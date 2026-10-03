import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/class_session.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_stats.dart';
import '../../domain/schedule_engine.dart';
import '../../services/notification_service.dart';
import '../../state/providers.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/nav_bar_scroll.dart';
import '../subjects/class_editor_sheets.dart';
import '../timetable/week_grid_view.dart';
import 'day_page.dart';
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
///
/// The day's classes sit in a pager, so dragging sideways carries them across
/// and settles on the next day rather than waiting for you to let go. Being a
/// horizontal scrollable it also keeps the drag away from the shell's own
/// pager, which is why Today is the one tab you leave by tapping.
class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  /// Clearance under the grid for the floating button.
  static const double _gridBottomPad = 96;

  /// Where the pager counts from. Far enough in that neither end is reachable
  /// by dragging — a term is a few hundred days, not twenty thousand.
  static const int basePage = 20000;

  /// The two views move by different units, so each has its own pager and the
  /// same date maps to a different page in each.
  static int pageFor(HomeView view, DateTime origin, DateTime date) =>
      view == HomeView.grid
          ? basePage + Dates.daysBetween(origin, Dates.startOfWeek(date)) ~/ 7
          : basePage + Dates.daysBetween(origin, date);

  static DateTime dateForPage(HomeView view, DateTime origin, int page) =>
      Dates.addDays(
          origin, (page - basePage) * (view == HomeView.grid ? 7 : 1));

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  static const double _gridBottomPad = TodayScreen._gridBottomPad;

  /// Fixed for the life of the screen: a pager whose origin moved at midnight
  /// would renumber every page under the controller.
  late final DateTime _origin;

  /// Both built up front rather than on first use — a lazy one would be
  /// created by [dispose] reaching for it, which is too late to read a
  /// provider.
  late final PageController _dayPages;
  late final PageController _weekPages;

  @override
  void initState() {
    super.initState();
    _origin = Dates.startOfWeek(Dates.today());
    final DateTime selected = ref.read(selectedDateProvider);
    _dayPages = PageController(
      initialPage: TodayScreen.pageFor(HomeView.day, _origin, selected),
    );
    _weekPages = PageController(
      initialPage: TodayScreen.pageFor(HomeView.grid, _origin, selected),
    );
    // Warnings the notification tray is no longer carrying have to surface
    // somewhere. Immediately as well as on change, because whether the tray
    // is blocked is only known after the first frame. Post-frame keeps the
    // dialog out of the build phase; the announced set stops a repeat.
    ref.listenManual<List<SubjectStats>>(
      inAppAlertsProvider,
      (List<SubjectStats>? _, List<SubjectStats> __) =>
          WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showPendingAlerts(context, ref);
      }),
      fireImmediately: true,
    );
  }

  PageController _pagesFor(HomeView view) =>
      view == HomeView.grid ? _weekPages : _dayPages;

  @override
  void dispose() {
    _dayPages.dispose();
    _weekPages.dispose();
    super.dispose();
  }

  /// Brings a pager onto the day the rest of the app is showing — a tapped
  /// day pill, "jump to today", the unmarked banner, or the view it was not
  /// showing while the other one moved.
  void _followDate(HomeView view, DateTime date, {required bool animate}) {
    final PageController pages = _pagesFor(view);
    if (!pages.hasClients) return;
    final int target = TodayScreen.pageFor(view, _origin, date);
    if ((pages.page ?? target.toDouble()).round() == target) return;
    if (!animate) {
      pages.jumpToPage(target);
      return;
    }
    unawaited(pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutQuart,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final DateTime selected = ref.watch(selectedDateProvider);
    final TimetableData? data = ref.watch(timetableProvider).value;
    final HomeView view = ref.watch(homeViewProvider);
    final NavBarScroll? navBar = NavBarScroll.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    final double cap = AppScale.contentWidth(screen);
    final EdgeInsets column = EdgeInsets.symmetric(
      horizontal: screen.width > cap ? (screen.width - cap) / 2 : 0,
    );

    // A date set anywhere else has to reach the pager: the day pills, the
    // header arrows, "jump to today", the unmarked banner.
    ref.listen<DateTime>(selectedDateProvider, (DateTime? _, DateTime next) {
      _followDate(ref.read(homeViewProvider), next, animate: true);
    });
    // Switching views hands over to a pager that was left on an older date,
    // and it is not on screen yet, so there is nothing to animate.
    ref.listen<HomeView>(homeViewProvider, (HomeView? _, HomeView next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _followDate(next, ref.read(selectedDateProvider), animate: false);
        }
      });
    });

    return GradientScaffold(
      header:
          view == HomeView.grid ? _gridHeader(selected) : _dayHeader(selected),
      // On a first run the empty state carries the same button, larger.
      floatingActionButton:
          (data?.slots.isEmpty ?? true) && (data?.extras.isEmpty ?? true)
              ? null
              : GradientFab(
                  label: 'Add class',
                  onPressed: () =>
                      showAddClassSheet(context, ref, initialDate: selected),
                ),
      body: PageView.builder(
        controller: _pagesFor(view),
        onPageChanged: (int page) {
          // A day whose classes fit the screen has nothing to scroll back up,
          // so arriving on one with the bar already gone would strand it.
          navBar?.show();
          ref
              .read(selectedDateProvider.notifier)
              .select(TodayScreen.dateForPage(view, _origin, page));
        },
        itemBuilder: (BuildContext context, int page) {
          final DateTime date = TodayScreen.dateForPage(view, _origin, page);
          // Reported from inside the date pager, which the shell's own listener
          // sits outside of: from there this list is one viewport too deep for
          // [RootShell.navVisibleFor] to act on.
          return NotificationListener<UserScrollNotification>(
            onNotification: navBar?.report ?? (_) => false,
            child: RefreshIndicator(
              color: p.accent,
              backgroundColor: p.surface,
              onRefresh: () async => ref.invalidate(timetableProvider),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: <Widget>[
                  if (view == HomeView.grid)
                    _weekPage(Dates.startOfWeek(date))
                  else
                    TodayDayPage(date: date, column: column),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// The grid follows whichever day you were looking at, so switching views
  /// does not lose your place and needs no state of its own.
  Widget _gridHeader(DateTime selected) {
    final DateTime week = Dates.startOfWeek(selected);
    final Map<int, List<ClassSession>> byDay =
        ref.watch(scheduleEngineProvider)?.sessionsForWeekOf(week) ??
            const <int, List<ClassSession>>{};
    return _GridHeader(
      weekStart: week,
      count: byDay.values
          .fold<int>(0, (int sum, List<ClassSession> v) => sum + v.length),
      onShift: (int weeks) =>
          ref.read(selectedDateProvider.notifier).shiftDays(weeks * 7),
      onToday: () => ref.read(selectedDateProvider.notifier).goToToday(),
      onToggleView: () => ref.read(homeViewProvider.notifier).toggle(),
    );
  }

  Widget _dayHeader(DateTime selected) => _DayHeader(
        selected: selected,
        isToday: Dates.isSameDay(selected, Dates.today()),
        stats: ref.watch(statsProvider),
        settings: ref.watch(settingsProvider).value ?? const AppSettings(),
        markers: ref.watch(dayMarkersProvider),
        onSelectDay: (DateTime date) =>
            ref.read(selectedDateProvider.notifier).select(date),
        onJumpToToday: () =>
            ref.read(selectedDateProvider.notifier).goToToday(),
        onToggleView: () => ref.read(homeViewProvider.notifier).toggle(),
      );

  Widget _weekPage(DateTime weekStart) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, _gridBottomPad),
        // The viewport, not what is left to paint — that shrinks as you
        // scroll and would resize the blocks under your finger.
        sliver: SliverLayoutBuilder(
          builder: (BuildContext context, SliverConstraints c) =>
              SliverToBoxAdapter(
            child: WeekGridView(
              weekStart: weekStart,
              // Less this sliver's own padding, which the viewport extent does
              // not know about.
              availableHeight: c.viewportMainAxisExtent -
                  c.precedingScrollExtent -
                  _gridBottomPad,
            ),
          ),
        ),
      );

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
    unawaited(showDialog<void>(
      context: context,
      builder: (BuildContext context) => _InAppAlertDialog(alerts: pending),
    ));
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
                    if (stats.verdictDetail
                        case final String detail) ...<Widget>[
                      const SizedBox(height: 4),
                      HeaderCaption(detail),
                    ],
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

  /// The second half of the caption, present only when there is a term to
  /// count down. Without dates the app has nothing to say here, and inventing
  /// a number would be worse than saying nothing.
  String _termTail(AppSettings settings) {
    final DateTime? end = settings.termEnd;
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
                      '${kMonthNamesShort[weekEnd.month - 1]}',
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
/// [NotificationService.dangerTitle] and [NotificationService.dangerMessage]
/// so the wording matches the tray exactly.
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
      title: Text(NotificationService.dangerTitle(alerts.length)),
      // One row per subject, so a phone can run out of height; the list
      // scrolls and the title and Got it stay put.
      content: SingleChildScrollView(
        child: Column(
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
                        fontSize: AppType.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      NotificationService.dangerMessage(s),
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: AppType.bodyMedium,
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
                fontSize: AppType.labelLarge,
                height: 1.35,
              ),
            ),
          ],
        ),
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
