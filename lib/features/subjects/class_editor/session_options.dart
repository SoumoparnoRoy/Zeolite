import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../core/words.dart';
import '../../../data/models/attendance_record.dart';
import '../../../data/models/attendance_status.dart';
import '../../../data/models/class_session.dart';
import '../../../data/models/class_slot.dart';
import '../../../data/models/extra_class.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';
import '../../../widgets/undo_snack.dart';

import 'extra_class_editor.dart';
import 'occurrence_editor.dart';
import 'slot_editor.dart';

/// Opens the right editor for whatever produced [session] — the weekly rule
/// behind a recurring class, or the one-off class itself.
///
/// A session is derived, so it carries only the id of its origin. Resolving
/// that id in one place keeps the Today screen, the Timetable screen and the
/// options sheet from each growing their own lookup.
Future<void> showSessionEditor(
  BuildContext context,
  WidgetRef ref,
  ClassSession session,
) async {
  final TimetableData? data = ref.read(timetableProvider).value;
  if (data == null) return;

  if (session.slotId != null) {
    for (final ClassSlot slot in data.slots) {
      if (slot.id != session.slotId) continue;
      await showSlotEditor(context, ref, slot: slot);
      return;
    }
    return;
  }

  for (final ExtraClass extra in data.extras) {
    if (extra.id != session.extraClassId) continue;
    await showExtraClassEditor(context, ref, extra: extra);
    return;
  }
}

/// The count is the part worth reading, so the dialog names it rather than
/// asking "are you sure".
Future<bool> _confirmEndWithMarks(
  BuildContext context,
  String subjectName,
  String from,
  int markCount,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('Stop repeating and remove its attendance?'),
      content: Text(
        '$subjectName stops repeating from $from, and the '
        '${Words.plural(markCount, 'mark')} recorded from then on go with it. '
        'Earlier weeks keep theirs.',
        style: const TextStyle(height: 1.4),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: context.palette.absent),
          child: const Text('Stop and remove'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<bool> _confirmDeleteWithMarks(
  BuildContext context,
  String subjectName,
  int markCount,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('Delete the class and its attendance?'),
      content: Text(
        '$subjectName loses this class from every week, past ones included, '
        'and the ${Words.plural(markCount, 'mark')} recorded against it.',
        style: const TextStyle(height: 1.4),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: context.palette.absent),
          child: const Text('Delete both'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Long-press menu on a class: edit it, cancel just this one, stop it
/// repeating, or remove it entirely.
Future<void> showSessionOptions(
  BuildContext context,
  WidgetRef ref,
  ClassSession session, {
  /// The screen behind already opens the editor on a tap.
  bool tapOpensEditor = false,

  /// The screen behind already carries the status buttons.
  bool marksInline = false,
}) async {
  final TimetableData? data = ref.read(timetableProvider).value;
  ClassSlot? slot;
  for (final ClassSlot candidate in data?.slots ?? <ClassSlot>[]) {
    if (candidate.id == session.slotId) slot = candidate;
  }
  // Only the marks from the long-pressed date on: the weeks before the cut
  // keep theirs, so they are not what the warning is about.
  final int endingMarkCount = slot == null
      ? 0
      : (data?.records ?? <AttendanceRecord>[])
          .where((AttendanceRecord r) =>
              slot!.covers(r) &&
              Dates.keyOf(r.date) >= Dates.keyOf(session.date))
          .length;

  // With nothing marked the two deletes would do the same thing.
  final int markCount = slot == null
      ? 0
      : (data?.records ?? <AttendanceRecord>[]).where(slot.covers).length;

  // Grabbed before the sheet opens: every option below pops it first, so the
  // undo offer has to be raised through something that outlives the route.
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final ActionCore core = ref.read(actionCoreProvider);
  final ScheduleActions schedule = ref.read(scheduleActionsProvider);

  await showAppSheet<void>(
    context: context,
    title: session.subject.name,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (slot != null) ...<Widget>[
          _OptionTile(
            icon: Icons.edit_calendar_outlined,
            title: 'Edit just this class',
            subtitle: 'Changes the time, room or subject for '
                '${Dates.formatDayMonth(session.date)} alone. Every other week '
                'keeps the weekly class as it is.',
            onTap: () async {
              Navigator.of(context).pop();
              await showOccurrenceEditor(
                context,
                ref,
                slot: slot!,
                date: session.date,
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (!tapOpensEditor)
          _OptionTile(
            icon: Icons.edit_outlined,
            title: session.slotId != null
                ? 'Edit the weekly class'
                : 'Edit this class',
            subtitle: session.slotId != null
                // Only mentioned where it is true, so the promise of "every
                // week" is not quietly contradicted by a week set by hand.
                ? 'Changes the day, time, room or subject for every week, '
                    'including the ones already past.'
                    '${data?.hasOverridesFor(session.slotId) ?? false ? ' Weeks you edited on their own keep what you set.' : ''}'
                : 'Changes the date, time, room or subject.',
            onTap: () async {
              Navigator.of(context).pop();
              await showSessionEditor(context, ref, session);
            },
          ),
        if (slot != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _OptionTile(
            icon: Icons.event_busy_outlined,
            title: 'Delete just this class',
            subtitle: session.isMarked
                ? 'Removes '
                    '${Dates.formatDayMonth(session.date)} from your timetable, '
                    'and the mark recorded against it. Every other week stays.'
                : 'Removes ${Dates.formatDayMonth(session.date)} from your '
                    'timetable. Every other week stays.',
            danger: true,
            onTap: () async {
              Navigator.of(context).pop();
              await schedule.skipSlotOn(slot!, session.date);
              showUndoSnack(
                messenger,
                core,
                '${session.subject.name} on '
                '${Dates.formatDayMonth(session.date)} removed',
              );
            },
          ),
        ],
        if (slot == null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _OptionTile(
            icon: Icons.block_rounded,
            title: 'Cancel just this class',
            subtitle:
                'Marks ${Dates.formatDayMonth(session.date)} as cancelled. It stops counting towards your percentage.',
            onTap: () async {
              Navigator.of(context).pop();
              await ref
                  .read(attendanceActionsProvider)
                  .mark(session, AttendanceStatus.cancelled);
            },
          ),
        ],
        if (session.slotId != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _OptionTile(
            icon: Icons.event_busy_rounded,
            title: 'Stop repeating from this date',
            subtitle: endingMarkCount > 0
                ? 'Stops the class from '
                    '${Dates.formatDayMonth(session.date)}, this one included, '
                    'along with the '
                    '${Words.plural(endingMarkCount, 'mark')} recorded from '
                    'then on. Earlier weeks keep theirs.'
                : 'Stops the class from '
                    '${Dates.formatDayMonth(session.date)}, this one included. '
                    'Earlier weeks are kept, and so is everything already '
                    'recorded.',
            onTap: () async {
              if (endingMarkCount > 0) {
                final bool confirmed = await _confirmEndWithMarks(
                  context,
                  session.subject.name,
                  Dates.formatDayMonth(session.date),
                  endingMarkCount,
                );
                if (!confirmed || !context.mounted) return;
              }
              Navigator.of(context).pop();
              if (slot != null && endingMarkCount > 0) {
                await schedule.endSlotFromAndClearMarks(slot, session.date);
              } else {
                await schedule.endSlotFrom(session.slotId!, session.date);
              }
              showUndoSnack(
                messenger,
                core,
                endingMarkCount > 0
                    ? '${session.subject.name} stops repeating from '
                        '${Dates.formatDayMonth(session.date)}, and its '
                        '${Words.plural(endingMarkCount, 'mark')} from then '
                        'on are gone'
                    : '${session.subject.name} stops repeating from '
                        '${Dates.formatDayMonth(session.date)}',
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
          _OptionTile(
            icon: Icons.delete_outline_rounded,
            title: 'Delete this weekly class',
            subtitle: markCount > 0
                ? 'Removes the class from every week, past ones included, '
                    'along with the ${Words.plural(markCount, 'mark')} '
                    'recorded against it. Your percentage will change.'
                : 'Removes the class from every week, past ones included.',
            danger: true,
            onTap: () async {
              if (markCount > 0) {
                final bool confirmed = await _confirmDeleteWithMarks(
                  context,
                  session.subject.name,
                  markCount,
                );
                if (!confirmed || !context.mounted) return;
              }
              Navigator.of(context).pop();
              if (slot != null) {
                await schedule.deleteSlotAndMarks(slot);
              } else {
                await schedule.deleteSlot(session.slotId!);
              }
              showUndoSnack(
                messenger,
                core,
                markCount > 0
                    ? 'Weekly ${session.subject.name} and its '
                        '${Words.plural(markCount, 'mark')} deleted'
                    : 'Weekly ${session.subject.name} deleted',
              );
            },
          ),
        ],
        if (session.extraClassId != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _OptionTile(
            icon: Icons.delete_outline_rounded,
            title: 'Delete this one-off class',
            subtitle: 'Removes it from your timetable.',
            danger: true,
            onTap: () async {
              Navigator.of(context).pop();
              await schedule.deleteExtraClass(session.extraClassId!);
              showUndoSnack(
                messenger,
                core,
                'One-off ${session.subject.name} deleted',
              );
            },
          ),
        ],
        if (session.isMarked && !marksInline) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _OptionTile(
            icon: Icons.undo_rounded,
            title: 'Clear the mark',
            subtitle: 'Sets this class back to unmarked.',
            onTap: () async {
              Navigator.of(context).pop();
              await ref.read(attendanceActionsProvider).clearMark(session);
            },
          ),
        ],
      ],
    ),
  );
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color color =
        danger ? context.palette.absent : context.palette.textPrimary;
    return SurfaceCard(
      color: context.palette.surfaceHigher,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: context.palette.textSecondary,
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
