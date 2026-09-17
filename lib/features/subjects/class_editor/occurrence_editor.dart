import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../core/time_picker.dart';
import '../../../data/models/class_session.dart';
import '../../../data/models/class_slot.dart';
import '../../../data/models/slot_override.dart';
import '../../../domain/class_clash.dart';
import '../../../domain/schedule_engine.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';

import 'editor_fields.dart';

/// Edits a single week of a weekly rule.
///
/// The date is fixed and not offered: the occurrence *is* that date, and a
/// picker would let the sheet contradict the day behind it. Weight is not
/// offered either — what one class is worth belongs to the rule.
Future<void> showOccurrenceEditor(
  BuildContext context,
  WidgetRef ref, {
  required ClassSlot slot,
  required DateTime date,
}) {
  return showAppSheet<void>(
    context: context,
    // formatDayMonth already carries the weekday, so naming it again here
    // reads as 'Monday, Mon, 14 Sep'.
    title: '${Dates.weekdayLong(date)}, ${Dates.formatFull(date)}',
    child: _OccurrenceForm(slot: slot, date: date),
  );
}

class _OccurrenceForm extends ConsumerStatefulWidget {
  const _OccurrenceForm({required this.slot, required this.date});

  final ClassSlot slot;
  final DateTime date;

  @override
  ConsumerState<_OccurrenceForm> createState() => _OccurrenceFormState();
}

class _OccurrenceFormState extends ConsumerState<_OccurrenceForm> {
  int? _subjectId;
  int _start = 9 * 60;
  int _end = 10 * 60;
  late final TextEditingController _room;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Seeded from the week as it currently reads, so re-opening an edited week
    // shows what is on screen rather than the rule underneath it.
    final ClassSlot shown = ref
            .read(timetableProvider)
            .value
            ?.overrideOn(widget.slot.id, widget.date)
            ?.applyTo(widget.slot) ??
        widget.slot;
    _subjectId = shown.subjectId;
    _start = shown.startMinutes;
    _end = shown.endMinutes;
    _room = TextEditingController(text: shown.room ?? '');
  }

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  Future<void> _pickTime({required bool isStart}) async {
    final int current = isStart ? _start : _end;
    final TimeOfDay? picked = await showAppTimePicker(
      context,
      initialTime: TimeOfDay(
        hour: Clock.hourOf(current),
        minute: Clock.minuteOf(current),
      ),
      use24Hour: ref.read(settingsProvider).value?.use24HourTime ?? false,
    );
    if (picked == null || !mounted) return;
    setState(() {
      final int value = picked.hour * 60 + picked.minute;
      if (isStart) {
        final int length = _end - _start;
        _start = value;
        _end = value + (length > 0 ? length : 60);
      } else {
        _end = value;
      }
    });
  }

  /// Whether another class already owns the attendance key this week would
  /// move onto.
  ///
  /// Asked of the engine rather than of [ClassClash] because the engine has
  /// already applied every other override for the day, and because the rule
  /// being edited has to be excluded — it would otherwise collide with itself
  /// on a change that leaves subject and start time alone.
  bool _collides(int subjectId, int start) {
    final ScheduleEngine? engine = ref.read(scheduleEngineProvider);
    if (engine == null) return false;
    for (final ClassSession session in engine.sessionsOn(widget.date)) {
      if (session.slotId == widget.slot.id) continue;
      if (session.subject.id == subjectId && session.startMinutes == start) {
        return true;
      }
    }
    return false;
  }

  Future<void> _save() async {
    final int? subjectId = _subjectId;
    if (subjectId == null) {
      setState(() => _error = 'Choose a subject.');
      return;
    }
    if (_end <= _start) {
      setState(() => _error = 'The end time must be after the start time.');
      return;
    }
    if (_collides(subjectId, _start)) {
      setState(() {
        _error = 'This subject already has a class at '
            '${Clock.format(_start)} on '
            '${Dates.formatDayMonth(widget.date)}. Attendance is recorded per '
            'subject and start time, so the two would share one mark.';
      });
      return;
    }

    final String room = _room.text.trim();
    // Only what differs from the rule is stored, so a week that is edited back
    // to match its rule stops being an exception at all.
    final SlotOverride override = SlotOverride(
      slotId: widget.slot.id!,
      date: widget.date,
      subjectId: subjectId == widget.slot.subjectId ? null : subjectId,
      startMinutes: _start == widget.slot.startMinutes ? null : _start,
      endMinutes: _end == widget.slot.endMinutes ? null : _end,
      room: room == (widget.slot.room ?? '') ? null : room,
    );

    setState(() {
      _saving = true;
      _error = null;
    });
    await ref
        .read(scheduleActionsProvider)
        .setSlotOverride(widget.slot, widget.date, override);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bool use24Hour =
        ref.watch(settingsProvider).value?.use24HourTime ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Changes this week only. Every other week keeps the weekly class as '
          'it is.',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: context.palette.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        SubjectPicker(
          value: _subjectId,
          onChanged: (int? id) => setState(() => _subjectId = id),
        ),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('When'),
        Row(
          children: <Widget>[
            Expanded(
              child: FieldButton(
                label: 'Starts',
                value: Clock.format(_start, use24Hour: use24Hour),
                icon: Icons.schedule_rounded,
                onTap: () => _pickTime(isStart: true),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FieldButton(
                label: 'Ends',
                value: Clock.format(_end, use24Hour: use24Hour),
                icon: Icons.schedule_rounded,
                onTap: () => _pickTime(isStart: false),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Room'),
        RoomField(controller: _room),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Text(
            _error!,
            style: TextStyle(color: context.palette.absent, fontSize: 13),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save this week'),
        ),
      ],
    );
  }
}
