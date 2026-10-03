import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../core/words.dart';
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
  if (session.slotId != null) {
    final ClassSlot? slot = data?.slotById(session.slotId);
    if (slot != null) await showSlotEditor(context, ref, slot: slot);
    return;
  }
  final ExtraClass? extra = data?.extraById(session.extraClassId);
  if (extra != null) await showExtraClassEditor(context, ref, extra: extra);
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
  final _SessionOptions options = _SessionOptions(context, ref, session);
  await showAppSheet<void>(
    context: context,
    title: session.subject.name,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final (int i, Widget tile) in options
            .tiles(tapOpensEditor: tapOpensEditor, marksInline: marksInline)
            .indexed) ...<Widget>[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          tile,
        ],
      ],
    ),
  );
}

/// What the sheet offers for one class, and what each choice does.
///
/// Everything is read when the sheet opens. Every choice pops the sheet first,
/// so the undo offer is raised through a messenger that outlives the route.
class _SessionOptions {
  _SessionOptions(this.context, this.ref, this.session)
      : data = ref.read(timetableProvider).value,
        messenger = ScaffoldMessenger.of(context),
        core = ref.read(actionCoreProvider),
        schedule = ref.read(scheduleActionsProvider) {
    slot = data?.slotById(session.slotId);
  }

  final BuildContext context;
  final WidgetRef ref;
  final ClassSession session;
  final TimetableData? data;
  final ScaffoldMessengerState messenger;
  final ActionCore core;
  final ScheduleActions schedule;
  late final ClassSlot? slot;

  String get _day => Dates.formatDayMonth(session.date);
  String get _name => session.subject.name;

  /// Only the marks from the long-pressed date on: the weeks before the cut
  /// keep theirs, so they are not what the warning is about.
  late final int _endingMarks =
      slot == null ? 0 : data!.marksCoveredBy(slot!, from: session.date);

  /// With nothing marked the two deletes would do the same thing.
  late final int _allMarks = slot == null ? 0 : data!.marksCoveredBy(slot!);

  List<Widget> tiles({
    required bool tapOpensEditor,
    required bool marksInline,
  }) =>
      <Widget>[
        if (slot != null) _editThisOne(),
        if (!tapOpensEditor) _editTheClass(),
        if (slot != null) _deleteThisOne(),
        // Not on a class already cancelled: the mark toggles, so this would
        // quietly clear it instead.
        if (slot == null && session.status != AttendanceStatus.cancelled)
          _cancelThisOne(),
        if (session.slotId != null) ...<Widget>[
          _stopRepeating(),
          _deleteWeekly(),
        ],
        if (session.extraClassId != null) _deleteOneOff(),
        if (session.isMarked && !marksInline) _clearMark(),
      ];

  Widget _editThisOne() => _OptionTile(
        icon: Icons.edit_calendar_outlined,
        title: 'Edit just this class',
        subtitle: 'Changes the time, room or subject for $_day alone. Every '
            'other week keeps the weekly class as it is.',
        onTap: () async {
          Navigator.of(context).pop();
          await showOccurrenceEditor(
            context,
            ref,
            slot: slot!,
            date: session.date,
          );
        },
      );

  Widget _editTheClass() {
    final bool weekly = session.slotId != null;
    // Only mentioned where it is true, so the promise of "every week" is not
    // quietly contradicted by a week set by hand.
    final bool editedWeeks = data?.hasOverridesFor(session.slotId) ?? false;
    return _OptionTile(
      icon: Icons.edit_outlined,
      title: weekly ? 'Edit the weekly class' : 'Edit this class',
      subtitle: weekly
          ? 'Changes the day, time, room or subject for every week, including '
              'the ones already past.'
              '${editedWeeks ? ' Weeks you edited on their own keep what you set.' : ''}'
          : 'Changes the date, time, room or subject.',
      onTap: () async {
        Navigator.of(context).pop();
        await showSessionEditor(context, ref, session);
      },
    );
  }

  Widget _deleteThisOne() => _OptionTile(
        icon: Icons.event_busy_outlined,
        title: 'Delete just this class',
        subtitle: session.isMarked
            ? 'Removes $_day from your timetable, and the mark recorded '
                'against it. Every other week stays.'
            : 'Removes $_day from your timetable. Every other week stays.',
        danger: true,
        onTap: () async {
          Navigator.of(context).pop();
          await schedule.skipSlotOn(slot!, session.date);
          showUndoSnack(messenger, core, '$_name on $_day removed');
        },
      );

  Widget _cancelThisOne() {
    final bool cancelledCounts =
        ref.read(settingsProvider).value?.cancelledCountsAsAttended ?? false;
    return _OptionTile(
      icon: Icons.block_rounded,
      title: 'Cancel just this class',
      subtitle: 'Marks $_day as cancelled. ${cancelledCounts ? 'It counts as '
          'held and attended, as set in Settings.' : 'It stops counting '
          'towards your percentage.'}',
      onTap: () async {
        Navigator.of(context).pop();
        await ref
            .read(attendanceActionsProvider)
            .mark(session, AttendanceStatus.cancelled);
      },
    );
  }

  Widget _stopRepeating() => _OptionTile(
        icon: Icons.event_busy_rounded,
        title: 'Stop repeating from this date',
        subtitle: _endingMarks > 0
            ? 'Stops the class from $_day, this one included, along with the '
                '${Words.plural(_endingMarks, 'mark')} recorded from then on. '
                'Earlier weeks keep theirs.'
            : 'Stops the class from $_day, this one included. Earlier weeks '
                'are kept, and so is everything already recorded.',
        onTap: () async {
          if (_endingMarks > 0) {
            final bool confirmed =
                await _confirmEndWithMarks(context, _name, _day, _endingMarks);
            if (!confirmed || !context.mounted) return;
          }
          Navigator.of(context).pop();
          if (slot != null && _endingMarks > 0) {
            await schedule.endSlotFromAndClearMarks(slot!, session.date);
          } else {
            await schedule.endSlotFrom(session.slotId!, session.date);
          }
          showUndoSnack(
            messenger,
            core,
            _endingMarks > 0
                ? '$_name stops repeating from $_day, and its '
                    '${Words.plural(_endingMarks, 'mark')} from then on are '
                    'gone'
                : '$_name stops repeating from $_day',
          );
        },
      );

  Widget _deleteWeekly() => _OptionTile(
        icon: Icons.delete_outline_rounded,
        title: 'Delete this weekly class',
        subtitle: _allMarks > 0
            ? 'Removes the class from every week, past ones included, along '
                'with the ${Words.plural(_allMarks, 'mark')} recorded against '
                'it. Your percentage will change.'
            : 'Removes the class from every week, past ones included.',
        danger: true,
        onTap: () async {
          if (_allMarks > 0) {
            final bool confirmed =
                await _confirmDeleteWithMarks(context, _name, _allMarks);
            if (!confirmed || !context.mounted) return;
          }
          Navigator.of(context).pop();
          if (slot != null) {
            await schedule.deleteSlotAndMarks(slot!);
          } else {
            await schedule.deleteSlot(session.slotId!);
          }
          showUndoSnack(
            messenger,
            core,
            _allMarks > 0
                ? 'Weekly $_name and its '
                    '${Words.plural(_allMarks, 'mark')} deleted'
                : 'Weekly $_name deleted',
          );
        },
      );

  Widget _deleteOneOff() => _OptionTile(
        icon: Icons.delete_outline_rounded,
        title: 'Delete this one-off class',
        subtitle: 'Removes it from your timetable.',
        danger: true,
        onTap: () async {
          Navigator.of(context).pop();
          await schedule.deleteExtraClass(session.extraClassId!);
          showUndoSnack(messenger, core, 'One-off $_name deleted');
        },
      );

  Widget _clearMark() => _OptionTile(
        icon: Icons.undo_rounded,
        title: 'Clear the mark',
        subtitle: 'Sets this class back to unmarked.',
        onTap: () async {
          Navigator.of(context).pop();
          await ref.read(attendanceActionsProvider).clearMark(session);
          showUndoSnack(messenger, core, 'Mark cleared');
        },
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
