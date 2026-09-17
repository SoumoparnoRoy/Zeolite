import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../data/models/class_slot.dart';
import '../../../data/models/extra_class.dart';
import '../../../domain/class_clash.dart';
import '../../../domain/day_grid.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';

import 'editor_fields.dart';

/// Fills one cell of the block grid: choose a subject, how many blocks it runs
/// for, a room, and whether it repeats every week or happens once.
///
/// The times are not asked for — the cell already determines them, which is the
/// whole reason for filling a timetable in on a grid rather than in a form. A
/// one-off keeps its date for the same reason: the cell you tapped *is* the
/// date, so offering a picker would let the sheet contradict the grid behind it.
Future<void> showBlockClassEditor(
  BuildContext context,
  WidgetRef ref, {
  required DateTime date,
  required int blockIndex,
}) {
  return showAppSheet<void>(
    context: context,
    title: '${Dates.weekdayLong(date)} · block ${blockIndex + 1}',
    child: _BlockClassForm(date: date, blockIndex: blockIndex),
  );
}

class _BlockClassForm extends ConsumerStatefulWidget {
  const _BlockClassForm({required this.date, required this.blockIndex});

  final DateTime date;
  final int blockIndex;

  @override
  ConsumerState<_BlockClassForm> createState() => _BlockClassFormState();
}

class _BlockClassFormState extends ConsumerState<_BlockClassForm> {
  int? _subjectId;
  final TextEditingController _room = TextEditingController();
  late DateTime _startDate;

  /// Null until a subject is chosen, at which point it follows that subject's
  /// category. Set by hand it stays put, so a one-off long session is possible
  /// without editing the category.
  int? _blocks;

  /// A grid cell is normally how a timetable gets built, so the weekly rule is
  /// the default; a single make-up or rescheduled class is the exception.
  bool _repeatsWeekly = true;

  /// See the weekly form's `_weight`. Offered here too because filling the grid
  /// is how a timetable usually gets built.
  int _weight = 1;
  bool _weightTouched = false;

  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _startDate = widget.date;
  }

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  Future<void> _save(DayGrid grid, int blocks) async {
    if (_subjectId == null) {
      setState(() => _error = 'Choose a subject.');
      return;
    }
    final int start = grid.startOf(widget.blockIndex);
    final int end = Clock.endFromStart(start, blocks * grid.blockMinutes);
    final String? room = _room.text.trim().isEmpty ? null : _room.text.trim();

    final TimetableData? data = ref.read(timetableProvider).value;

    if (!_repeatsWeekly) {
      final ExtraClass proposed = ExtraClass(
        subjectId: _subjectId!,
        date: widget.date,
        startMinutes: start,
        endMinutes: end,
        room: room,
        weight: _weight,
      );
      // One call covers both halves here: another one-off on this date, and a
      // weekly rule whose window reaches it.
      if (data != null &&
          ClassClash.forOneOff(
            slots: data.slots,
            extras: data.extras,
            proposed: proposed,
          )) {
        setState(() {
          _error = 'This subject already has a class in this block on '
              '${Dates.formatDayMonth(widget.date)}. They would share one '
              'attendance mark.';
        });
        return;
      }

      setState(() {
        _saving = true;
        _error = null;
      });
      await ref.read(scheduleActionsProvider).addExtraClass(proposed);
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }

    for (final ClassSlot slot in data?.slots ?? <ClassSlot>[]) {
      if (slot.subjectId == _subjectId &&
          slot.weekday == widget.date.weekday &&
          slot.startMinutes == start) {
        setState(() {
          _error = 'This subject already has a class in this block on '
              '${Dates.weekdayLong(widget.date)}.';
        });
        return;
      }
    }

    final ClassSlot proposed = ClassSlot(
      subjectId: _subjectId!,
      weekday: widget.date.weekday,
      startMinutes: start,
      endMinutes: end,
      room: room,
      weight: _weight,
      startDate: _startDate,
    );

    if (data != null) {
      final DateTime? on =
          ClassClash.forWeekly(extras: data.extras, proposed: proposed);
      if (on != null) {
        setState(() {
          _error = 'A one-off class for this subject is already in this block '
              'on ${Dates.formatDayMonth(on)}. They would share one '
              'attendance mark.';
        });
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    await ref.read(scheduleActionsProvider).addSlot(proposed);

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final DayGrid grid = ref.watch(dayGridProvider);
    final bool use24Hour =
        ref.watch(settingsProvider).value?.use24HourTime ?? false;
    final int categoryBlocks =
        grid.blocksFor(ref.watch(defaultDurationProvider(_subjectId)));
    final int blocks = _blocks ?? categoryBlocks;

    // A class cannot run past the end of the day, but it always occupies at
    // least the block it starts in — a floor of zero would offer no lengths at
    // all and save a class ending the minute it began.
    final int remaining = grid.blockCount - widget.blockIndex;
    final int maxBlocks = remaining < 1 ? 1 : remaining;
    final int effective = blocks > maxBlocks ? maxBlocks : blocks;
    final int start = grid.startOf(widget.blockIndex);
    final int end = start + effective * grid.blockMinutes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SubjectPicker(
          value: _subjectId,
          onChanged: (int? id) => setState(() {
            _subjectId = id;
            _error = null;
            if (!_weightTouched) {
              _weight = ref.read(defaultWeightProvider(id));
            }
          }),
        ),
        const SizedBox(height: AppSpacing.xl),
        SectionHeader(
          'Length',
          trailing: Text(
            Clock.formatRange(start, end, use24Hour: use24Hour),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: context.palette.textTertiary,
            ),
          ),
        ),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (int n = 1; n <= maxBlocks && n <= 6; n++)
              DurationChip(
                minutes: n * grid.blockMinutes,
                label: '$n ${n == 1 ? 'block' : 'blocks'}',
                selected: n == effective,
                onTap: () => setState(() => _blocks = n),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          _subjectId == null
              ? 'Choosing a subject sets this from its category.'
              : ref.watch(defaultDurationLabelProvider(_subjectId)),
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: context.palette.textTertiary,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('Room'),
        RoomField(controller: _room),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('Repeats'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            OptionChip(
              label: 'Every week',
              selected: _repeatsWeekly,
              onTap: () => setState(() {
                _repeatsWeekly = true;
                _error = null;
              }),
            ),
            OptionChip(
              label: 'Just this once',
              selected: !_repeatsWeekly,
              onTap: () => setState(() {
                _repeatsWeekly = false;
                _error = null;
              }),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (_repeatsWeekly)
          FieldButton(
            label: 'First class',
            value: Dates.formatFull(_startDate),
            icon: Icons.play_arrow_rounded,
            onTap: () async {
              final DateTime? picked = await showDatePicker(
                context: context,
                initialDate: _startDate,
                firstDate: DateTime(DateTime.now().year - 2),
                lastDate: DateTime(DateTime.now().year + 3),
              );
              if (picked == null || !mounted) return;
              setState(() => _startDate = Dates.dayOf(picked));
            },
          )
        else
          Text(
            '${Dates.weekdayLong(widget.date)}, '
            '${Dates.formatFull(widget.date)} only. It will not appear in any '
            'other week.',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: context.palette.textTertiary,
            ),
          ),
        const SizedBox(height: AppSpacing.xl),
        WeightPicker(
          value: _weight,
          onChanged: (int n) => setState(() {
            _weight = n;
            _weightTouched = true;
          }),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Text(
            _error!,
            style: TextStyle(color: context.palette.absent, fontSize: 13),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          onPressed: _saving ? null : () => _save(grid, effective),
          child: Text(
            _repeatsWeekly ? 'Add to timetable' : 'Add one-off class',
          ),
        ),
      ],
    );
  }
}
