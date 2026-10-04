import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/class_session.dart';
import '../../data/models/class_slot.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/schedule_engine.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/class_editor_sheets.dart';

/// The weekly view: every class, day by day, with the tools to add, edit and
/// remove them.
class TimetableScreen extends ConsumerWidget {
  const TimetableScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime weekStart = ref.watch(visibleWeekProvider);
    final ScheduleEngine? engine = ref.watch(scheduleEngineProvider);
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final List<ClassSlot> slots =
        ref.watch(timetableProvider).value?.slots ?? <ClassSlot>[];

    final Map<int, List<ClassSession>> byDay =
        engine?.sessionsForWeekOf(weekStart) ?? <int, List<ClassSession>>{};
    final DateTime weekEnd = Dates.addDays(weekStart, 6);
    final bool isCurrentWeek =
        Dates.isSameDay(weekStart, Dates.startOfWeek(Dates.today()));
    final int weekTotal = byDay.values
        .fold<int>(0, (int sum, List<ClassSession> v) => sum + v.length);

    return GradientScaffold(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                HeaderEyebrow(
                  'Timetable · '
                  '${Dates.formatWeekRange(weekStart, weekEnd, year: true)}',
                ),
                const SizedBox(height: 7),
                HeaderTitle(
                  weekTotal == 0
                      ? 'No classes this week'
                      : '${Words.count(weekTotal)} '
                          '${Words.noun(weekTotal, 'class', 'classes')} this week',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: HeaderStepper(
              label: isCurrentWeek ? 'This week' : 'Back to this week',
              onBack: () =>
                  ref.read(visibleWeekProvider.notifier).shiftWeeks(-1),
              onForward: () =>
                  ref.read(visibleWeekProvider.notifier).shiftWeeks(1),
              onTapLabel: isCurrentWeek
                  ? null
                  : () => ref.read(visibleWeekProvider.notifier).goToThisWeek(),
            ),
          ),
        ],
      ),
      floatingActionButton: slots.isEmpty && weekTotal == 0
          ? null
          : GradientFab(
              label: 'Add class',
              onPressed: () => showAddClassSheet(context),
            ),
      slivers: <Widget>[
        if (slots.isEmpty && weekTotal == 0)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 40, bottom: 80),
              child: EmptyState(
                icon: Icons.calendar_month_outlined,
                title: 'Your timetable is empty',
                message: 'Add your weekly classes once and Zeolite will lay '
                    'out every week for you.',
                action: FilledButton.icon(
                  onPressed: () => showAddClassSheet(context),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add your first class'),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
            sliver: SliverList.builder(
              itemCount: 7,
              itemBuilder: (BuildContext context, int index) {
                final DateTime day = Dates.addDays(weekStart, index);
                return _DaySection(
                  day: day,
                  sessions: byDay[Dates.keyOf(day)] ?? const <ClassSession>[],
                  settings: settings,
                  holidayName: engine?.holidayOn(day)?.name,
                  onAdd: () => showAddClassSheet(context, initialDate: day),
                  // A tap marks here, so the sheet carries the editor and
                  // leaves clearing to the tap's own menu.
                  onLongPressSession: (ClassSession session) =>
                      showSessionOptions(context, ref, session,
                          marksInline: true),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// One day of the week: a hairline heading and the classes under it. No cards
/// — here a class is scanned rather than acted on, and seven boxed days made
/// a mostly-empty week look full.
class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.day,
    required this.sessions,
    required this.settings,
    required this.onAdd,
    required this.onLongPressSession,
    this.holidayName,
  });

  final DateTime day;
  final List<ClassSession> sessions;
  final AppSettings settings;
  final VoidCallback onAdd;
  final ValueChanged<ClassSession> onLongPressSession;
  final String? holidayName;

  @override
  Widget build(BuildContext context) {
    final bool isToday = Dates.isSameDay(day, Dates.today());
    final String? holiday = holidayName;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DayRule(
            label: '${Dates.weekdayShort(day)} ${Dates.formatFull(day)}'
                '${isToday ? ' · Today' : ''}',
            highlighted: isToday,
            onAdd: onAdd,
          ),
          if (holiday != null)
            _QuietRow(label: holiday, icon: Icons.celebration_rounded)
          else if (sessions.isEmpty)
            const _QuietRow(label: 'Free — no classes')
          else
            for (final ClassSession session in sessions)
              _SessionRow(
                session: session,
                use24Hour: settings.use24HourTime,
                onLongPress: () => onLongPressSession(session),
              ),
        ],
      ),
    );
  }
}

/// A day with nothing on it — one grey line, not an empty bordered box.
class _QuietRow extends StatelessWidget {
  const _QuietRow({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 11, 0, 3),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 13, color: p.textFaint),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.labelSmall,
                height: 1,
                fontWeight: FontWeight.w600,
                color: p.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the mark menu can do: set a status, or take the mark off.
enum _MarkChoice {
  present(AttendanceStatus.present),
  absent(AttendanceStatus.absent),
  cancelled(AttendanceStatus.cancelled),
  clear(null);

  const _MarkChoice(this.status);

  final AttendanceStatus? status;
}

class _SessionRow extends ConsumerWidget {
  const _SessionRow({
    required this.session,
    required this.use24Hour,
    required this.onLongPress,
  });

  final ClassSession session;
  final bool use24Hour;
  final VoidCallback onLongPress;

  /// Opens beside the row's right edge, where its status is written.
  Future<void> _chooseMark(BuildContext context, WidgetRef ref) async {
    final AppPalette p = context.palette;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ActionCore core = ref.read(actionCoreProvider);
    final AttendanceActions attendance = ref.read(attendanceActionsProvider);
    final RenderBox row = context.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final Rect at =
        row.localToGlobal(Offset.zero, ancestor: overlay) & row.size;
    final AttendanceStatus? current = session.status;

    final _MarkChoice? choice = await showMenu<_MarkChoice>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTRB(at.right, at.top, at.right, at.bottom),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<_MarkChoice>>[
        for (final _MarkChoice c in _MarkChoice.values)
          if (c.status case final AttendanceStatus status)
            PopupMenuItem<_MarkChoice>(
              value: c,
              child: _MarkItem(
                icon: status == current
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                label: status.label,
                color: status.colorIn(p),
                picked: status == current,
              ),
            ),
        if (current != null) ...<PopupMenuEntry<_MarkChoice>>[
          const PopupMenuDivider(),
          PopupMenuItem<_MarkChoice>(
            value: _MarkChoice.clear,
            child: _MarkItem(
              icon: Icons.undo_rounded,
              label: 'Clear the mark',
              color: p.textSecondary,
            ),
          ),
        ],
      ],
    );
    if (choice == null) return;
    final AttendanceStatus? status = choice.status;
    if (status == null) {
      await attendance.clearMark(session);
      showMarkCleared(messenger, core);
    } else if (status != current) {
      // Not for the current status: mark() reads that tap as clearing it.
      await attendance.mark(session, status);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    final AttendanceStatus? status = session.status;
    final bool isCancelled = status == AttendanceStatus.cancelled;

    return Semantics(
      onTapHint: 'Change the mark',
      onLongPressHint: 'Class options',
      child: InkWell(
        onTap: () => _chooseMark(context, ref),
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Opacity(
          opacity: isCancelled ? 0.55 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: <Widget>[
                SubjectAvatar(
                  initials: session.subject.initials,
                  color: session.subject.color,
                  size: 34,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        session.subject.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.bodyMedium,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: p.textPrimary,
                          decoration:
                              isCancelled ? TextDecoration.lineThrough : null,
                          decorationColor: p.textFaint,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        <String>[
                          Clock.formatRange(
                            session.startMinutes,
                            session.endMinutes,
                            use24Hour: use24Hour,
                          ),
                          if (session.room != null && session.room!.isNotEmpty)
                            session.room!,
                          if (session.isExtra) 'One-off',
                          if (isCancelled) 'Cancelled',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                            color: p.textTertiary, size: AppType.captionMedium),
                      ),
                    ],
                  ),
                ),
                // Named rather than a coloured dot, which nobody could read as
                // "you were marked absent" without being told.
                if (status != null && !isCancelled) ...<Widget>[
                  const SizedBox(width: 8),
                  Text(
                    status.label,
                    style: TextStyle(
                      fontSize: AppType.labelSmall,
                      fontWeight: FontWeight.w700,
                      color: status.colorIn(p),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MarkItem extends StatelessWidget {
  const _MarkItem({
    required this.icon,
    required this.label,
    required this.color,
    this.picked = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool picked;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppType.titleMedium,
              fontWeight: picked ? FontWeight.w700 : FontWeight.w500,
              color: context.palette.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
