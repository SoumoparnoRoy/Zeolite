import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/class_session.dart';
import '../../data/models/holiday.dart';
import '../../data/models/tag.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/schedule_engine.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/tag_picker.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/class_editor_sheets.dart';
import 'session_card.dart';

/// One day on Today: its notices, then a card per class to mark.
///
/// A group of slivers rather than a box, so it sits in the page's scroll view
/// exactly where the slivers it replaced did.
class TodayDayPage extends ConsumerWidget {
  const TodayDayPage({super.key, required this.date, required this.column});

  final DateTime date;

  /// The centred column every screen keeps to. Applied to each sliver rather
  /// than to the pager, so a swipe anywhere still turns the day.
  final EdgeInsets column;

  static const double _pad = 20;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
    final List<ClassSession> sessions =
        engine?.sessionsOn(date) ?? const <ClassSession>[];
    final Holiday? holiday = engine?.holidayOn(date);
    final bool outsideTerm = engine?.isOutsideTerm(date) ?? false;
    final List<ClassSession> unmarked = ref.watch(unmarkedSessionsProvider);

    return SliverMainAxisGroup(
      slivers: <Widget>[
        for (final Widget sliver in <Widget>[
          _padded(_title(context, ref, sessions), bottom: 14),
          if (unmarked.isNotEmpty)
            _padded(
              _UnmarkedBanner(
                count: unmarked.length,
                onJump: () => ref
                    .read(selectedDateProvider.notifier)
                    .select(unmarked.first.date),
              ),
            ),
          if (_notice(context, ref, holiday, outsideTerm)
              case final Widget notice)
            _padded(notice),
          if (sessions.isEmpty && holiday == null && !outsideTerm)
            SliverToBoxAdapter(child: _empty(context, ref)),
          _cards(context, ref, sessions),
        ])
          SliverPadding(padding: column, sliver: sliver),
      ],
    );
  }

  static Widget _padded(Widget child, {double bottom = 12}) => SliverPadding(
        padding: EdgeInsets.fromLTRB(_pad, 0, _pad, bottom),
        sliver: SliverToBoxAdapter(child: child),
      );

  bool get _isToday => Dates.isSameDay(date, Dates.today());

  Widget _title(
    BuildContext context,
    WidgetRef ref,
    List<ClassSession> sessions,
  ) {
    final AppPalette p = context.palette;
    final int unmarkedHere =
        sessions.where((ClassSession s) => s.needsMarking).length;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            _isToday ? "Today's classes" : Dates.formatDayMonth(date),
            style: TextStyle(
              fontSize: AppType.bodyLarge,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
              color: p.textPrimary,
            ),
          ),
        ),
        if (unmarkedHere > 1)
          InkWell(
            onTap: () => _markAllPresent(context, ref, sessions),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                'All present',
                style: TextStyle(
                  fontSize: AppType.captionLarge,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: p.accent,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget? _notice(
    BuildContext context,
    WidgetRef ref,
    Holiday? holiday,
    bool outsideTerm,
  ) {
    final AppPalette p = context.palette;
    if (holiday != null) {
      return _NoticeCard(
        icon: Icons.celebration_rounded,
        title: holiday.name,
        message: 'Marked as a holiday — no recurring classes '
            '${_isToday ? 'today' : 'that day'}.',
        color: p.cyan,
      );
    }
    if (!outsideTerm) return null;
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    return _NoticeCard(
      icon: Icons.event_busy_rounded,
      title: 'Outside the term',
      message: settings.hasTerm
          ? 'Your term runs ${Dates.formatFull(settings.termStart!)} – '
              '${Dates.formatFull(settings.termEnd!)}.'
          : 'Set your term dates in Settings.',
      color: p.textTertiary,
    );
  }

  Widget _empty(BuildContext context, WidgetRef ref) {
    final TimetableData? timetable = ref.watch(timetableProvider).value;
    final bool nothingScheduled = (timetable?.slots.isEmpty ?? true) &&
        (timetable?.extras.isEmpty ?? true);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      // A timetable with nothing in it at all is a first run, not a free day —
      // "enjoy the free day" told someone who had just finished setting up
      // that the schedule they have not made yet is clear.
      child: nothingScheduled
          ? EmptyState(
              icon: Icons.event_note_outlined,
              title: 'No classes yet',
              message: 'Add your first class and Zeolite starts tracking '
                  'attendance for it.',
              action: FilledButton.icon(
                onPressed: () => showAddClassSheet(context, initialDate: date),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add your first class'),
              ),
            )
          : EmptyState(
              icon: Icons.wb_sunny_outlined,
              title: _isToday ? 'Nothing on today' : 'No classes',
              message: _isToday
                  ? 'Enjoy the free day. Add classes from the Timetable tab.'
                  : 'There are no classes scheduled for this day.',
            ),
    );
  }

  Widget _cards(
    BuildContext context,
    WidgetRef ref,
    List<ClassSession> sessions,
  ) {
    final TimetableData? timetable = ref.watch(timetableProvider).value;
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final ClassSession? next = ref.watch(nextSessionProvider);
    final List<Tag> tags = timetable?.tags ?? const <Tag>[];
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(_pad, 0, _pad, 96),
      sliver: SliverList.separated(
        itemCount: sessions.length,
        separatorBuilder: (_, __) => const SizedBox(height: SessionCard.gap),
        itemBuilder: (BuildContext context, int index) {
          final ClassSession session = sessions[index];
          return SessionCard(
            session: session,
            use24Hour: settings.use24HourTime,
            nextColor: index + 1 < sessions.length
                ? SessionCard.spineColorOf(
                    sessions[index + 1],
                    context.palette,
                  )
                : null,
            categoryName:
                timetable?.categoryById(session.effectiveCategoryId)?.name,
            tagName: timetable?.tagById(session.record?.tagId)?.name,
            isNext: next != null &&
                next.date == session.date &&
                next.startMinutes == session.startMinutes &&
                next.subject.id == session.subject.id,
            onMark: (AttendanceStatus status) =>
                _mark(context, ref, session, status),
            onTag: tags.isEmpty
                ? null
                : () => _pickTag(context, ref, session, tags),
            onLongPress: () =>
                showSessionOptions(context, ref, session, marksInline: true),
          );
        },
      ),
    );
  }

  /// Opens the tag picker for one marked class and writes the result.
  ///
  /// The toggle lives in `setTagAt`, so tapping the tag a class already has
  /// clears it here without this screen knowing the rule.
  static Future<void> _pickTag(
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
    await ref.read(attendanceActionsProvider).setTagAt(
          subjectId: subjectId,
          date: session.date,
          startMinutes: session.startMinutes,
          tagId: chosen,
        );
  }

  static Future<void> _mark(
    BuildContext context,
    WidgetRef ref,
    ClassSession session,
    AttendanceStatus status,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ActionCore core = ref.read(actionCoreProvider);
    final bool cleared =
        await ref.read(attendanceActionsProvider).mark(session, status);
    if (cleared) showMarkCleared(messenger, core);
  }

  static Future<void> _markAllPresent(
    BuildContext context,
    WidgetRef ref,
    List<ClassSession> sessions,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ActionCore core = ref.read(actionCoreProvider);
    final int count = await ref
        .read(attendanceActionsProvider)
        .markAll(sessions, AttendanceStatus.present);
    if (count == 0) return;
    showUndoSnack(
      messenger,
      core,
      'Marked ${Words.plural(count, 'class', 'classes')} present',
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
              '$count past ${Words.noun(count, 'class needs', 'classes need')} '
              'marking',
              style: TextStyle(
                fontSize: AppType.bodySmall,
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
                    fontSize: AppType.bodyMedium,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: AppType.captionLarge,
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
