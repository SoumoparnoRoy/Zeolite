import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../core/time_picker.dart';
import '../../../data/models/attendance_record.dart';
import '../../../data/models/class_category.dart';
import '../../../data/models/class_slot.dart';
import '../../../domain/class_clash.dart';
import '../../../domain/class_weight.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';

import 'editor_fields.dart';

/// Create or edit a weekly recurring class.
Future<void> showSlotEditor(
  BuildContext context,
  WidgetRef ref, {
  ClassSlot? slot,
  DateTime? initialDate,
}) {
  return showAppSheet<void>(
    context: context,
    title: slot == null ? 'Weekly class' : 'Edit weekly class',
    child: _SlotForm(slot: slot, initialDate: initialDate),
  );
}

class _SlotForm extends ConsumerStatefulWidget {
  const _SlotForm({this.slot, this.initialDate});

  final ClassSlot? slot;
  final DateTime? initialDate;

  @override
  ConsumerState<_SlotForm> createState() => _SlotFormState();
}

/// One meeting of a recurring class: a weekday, its times and its room.
///
/// A subject can meet more than once on the same day — a morning lecture and
/// an afternoon lab — and the room often differs per meeting, so every entry
/// is fully independent rather than sharing a time or a room.
class _ClassTime {
  _ClassTime({
    required this.weekday,
    required this.startMinutes,
    required this.endMinutes,
    String room = '',
  }) : roomController = TextEditingController(text: room);

  int weekday;
  int startMinutes;
  int endMinutes;
  final TextEditingController roomController;

  int get durationMinutes => endMinutes - startMinutes;

  String? get room {
    final String value = roomController.text.trim();
    return value.isEmpty ? null : value;
  }

  void dispose() => roomController.dispose();
}

class _SlotFormState extends ConsumerState<_SlotForm> {
  int? _subjectId;

  /// Every meeting this form will create. Order is irrelevant — the list is
  /// grouped by weekday for display and sorted on save.
  final List<_ClassTime> _times = <_ClassTime>[];

  /// The last times the user chose. A newly ticked day inherits them, so when
  /// the schedule *is* uniform it stays a couple of taps.
  int _lastStart = 9 * 60;
  int _lastEnd = 10 * 60;

  late DateTime _startDate;
  DateTime? _endDate;
  String? _error;
  bool _saving = false;

  /// One weight for the whole form rather than one per row: it follows from
  /// what the class *is*, and a subject's lab meetings are all labs.
  int _weight = 1;

  /// Set once the weight has been chosen by hand, or when an existing class
  /// was opened, after which changing the subject stops re-weighting it.
  bool _weightTouched = false;

  /// Set once an *end* time has been chosen by hand, after which changing the
  /// subject no longer re-lengths the rows. Picking a start time deliberately
  /// does not count: that chooses when the class sits, not how long it runs,
  /// so the category default should still apply to it.
  bool _durationTouched = false;

  bool get _isEditing => widget.slot != null;

  /// Null leaves the type to the subject.
  int? _categoryId;

  ClassCategory? get _ownType =>
      ref.read(timetableProvider).value?.categoryById(_categoryId);

  /// Length from the class's type, falling back to the subject's category
  /// and then the global setting.
  int get _defaultDuration =>
      _ownType?.defaultDurationMinutes ??
      ref.read(defaultDurationProvider(_subjectId));

  int get _defaultWeight => _ownType == null
      ? ref.read(defaultWeightProvider(_subjectId))
      : weightFor(_ownType);

  /// Re-lengths every row from the current default. Call inside setState.
  void _applyDefaultDurationToAll() {
    final int duration = _defaultDuration;
    for (final _ClassTime time in _times) {
      time.endMinutes = Clock.endFromStart(time.startMinutes, duration);
    }
    if (_times.isNotEmpty) _lastEnd = _times.first.endMinutes;
  }

  /// Selected weekdays, Monday first.
  List<int> get _days {
    final Set<int> unique = <int>{
      for (final _ClassTime time in _times) time.weekday,
    };
    return unique.toList()..sort();
  }

  List<_ClassTime> _timesOn(int weekday) {
    final List<_ClassTime> rows =
        _times.where((_ClassTime time) => time.weekday == weekday).toList();
    rows.sort((_ClassTime a, _ClassTime b) =>
        a.startMinutes.compareTo(b.startMinutes));
    return rows;
  }

  @override
  void initState() {
    super.initState();
    final ClassSlot? slot = widget.slot;
    final DateTime seed = widget.initialDate ?? Dates.today();
    _subjectId = slot?.subjectId;
    _categoryId = slot?.categoryId;

    if (slot != null) {
      _lastStart = slot.startMinutes;
      _lastEnd = slot.endMinutes;
      _times.add(
        _ClassTime(
          weekday: slot.weekday,
          startMinutes: slot.startMinutes,
          endMinutes: slot.endMinutes,
          room: slot.room ?? '',
        ),
      );
    } else {
      _times.add(
        _ClassTime(
          weekday: seed.weekday,
          startMinutes: _lastStart,
          endMinutes: _lastEnd,
        ),
      );
    }

    _startDate = slot?.startDate ?? seed;
    _endDate = slot?.endDate;
    // An existing slot already carries what its owner meant, so opening the
    // form must not re-weight it from the category.
    _weight = slot?.weight ?? _defaultWeight;
    _weightTouched = slot != null;
  }

  @override
  void dispose() {
    for (final _ClassTime time in _times) {
      time.dispose();
    }
    super.dispose();
  }

  void _toggleWeekday(int weekday) {
    setState(() {
      _error = null;

      if (_isEditing) {
        // Editing a single rule: picking a day moves it, it does not add one.
        _times.first.weekday = weekday;
        return;
      }

      final List<_ClassTime> existing = _timesOn(weekday);
      if (existing.isNotEmpty) {
        // Always leave at least one day selected.
        if (_days.length == 1) return;
        for (final _ClassTime time in existing) {
          _times.remove(time);
          time.dispose();
        }
        return;
      }

      _times.add(
        _ClassTime(
          weekday: weekday,
          startMinutes: _lastStart,
          endMinutes: _lastEnd,
        ),
      );
    });
  }

  /// Adds another meeting on [weekday], starting when the previous one ends —
  /// which is usually what a second class that day looks like.
  void _addTimeOn(int weekday) {
    setState(() {
      _error = null;
      final List<_ClassTime> rows = _timesOn(weekday);
      final int duration = _defaultDuration;
      int start = rows.isEmpty ? _lastStart : rows.last.endMinutes;
      if (start > Clock.minutesPerDay - duration - 5) {
        start = Clock.minutesPerDay - duration - 5;
      }
      if (start < 0) start = 0;
      _times.add(
        _ClassTime(
          weekday: weekday,
          startMinutes: start,
          endMinutes: Clock.endFromStart(start, duration),
        ),
      );
    });
  }

  void _removeTime(_ClassTime time) {
    setState(() {
      if (_times.length == 1) return;
      _times.remove(time);
      time.dispose();
      _error = null;
    });
  }

  Future<void> _pickTime(_ClassTime time, {required bool isStart}) async {
    final int current = isStart ? time.startMinutes : time.endMinutes;
    final TimeOfDay? picked = await showAppTimePicker(
      context,
      initialTime: TimeOfDay(
        hour: Clock.hourOf(current),
        minute: Clock.minuteOf(current),
      ),
      use24Hour: ref.read(settingsProvider).value?.use24HourTime ?? false,
      helpText: '${kWeekdayNamesLong[time.weekday - 1]} · '
          '${isStart ? 'start time' : 'end time'}',
    );
    if (picked == null || !mounted) return;

    setState(() {
      _error = null;
      final int value = Clock.toMinutes(picked.hour, picked.minute);
      if (isStart) {
        // Setting a start fills the end in from the category's default length,
        // which is the whole point of categories. An end the user already set
        // by hand is kept, and only shifted to preserve its length.
        final int duration =
            _durationTouched ? time.durationMinutes : _defaultDuration;
        time.startMinutes = value;
        time.endMinutes = Clock.endFromStart(value, duration);
      } else {
        _durationTouched = true;
        time.endMinutes = value;
      }
      _lastStart = time.startMinutes;
      _lastEnd = time.endMinutes;
    });
  }

  Future<void> _pickDate({required bool isStart}) async {
    final DateTime initial =
        isStart ? _startDate : (_endDate ?? Dates.addDays(_startDate, 120));
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(DateTime.now().year - 2),
      lastDate: DateTime(DateTime.now().year + 3),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _startDate = Dates.dayOf(picked);
      } else {
        _endDate = Dates.dayOf(picked);
      }
    });
  }

  /// Two meetings of the same subject that start at the same minute on the
  /// same weekday would share one attendance key, so marking one would mark
  /// the other. They are rejected rather than silently merged.
  String? _validateClashes() {
    for (int i = 0; i < _times.length; i++) {
      for (int j = i + 1; j < _times.length; j++) {
        if (_times[i].weekday == _times[j].weekday &&
            _times[i].startMinutes == _times[j].startMinutes) {
          return 'Two classes on '
              '${kWeekdayNamesLong[_times[i].weekday - 1]} start at '
              '${Clock.format(_times[i].startMinutes)}. Give them different '
              'start times.';
        }
      }
    }

    final TimetableData? data = ref.read(timetableProvider).value;
    final List<ClassSlot> existing = data?.slots ?? <ClassSlot>[];
    for (final _ClassTime time in _times) {
      for (final ClassSlot slot in existing) {
        if (slot.subjectId != _subjectId) continue;
        if (slot.id == widget.slot?.id) continue;
        if (slot.weekday == time.weekday &&
            slot.startMinutes == time.startMinutes) {
          return 'This subject already has a class on '
              '${kWeekdayNamesLong[time.weekday - 1]} at '
              '${Clock.format(time.startMinutes)}.';
        }
      }
    }

    // The other half: a one-off class already sitting on a date this rule would
    // cover shares the same attendance key.
    if (data != null) {
      for (final _ClassTime time in _times) {
        final DateTime? on = ClassClash.forWeekly(
          extras: data.extras,
          proposed: ClassSlot(
            id: widget.slot?.id,
            subjectId: _subjectId!,
            weekday: time.weekday,
            startMinutes: time.startMinutes,
            endMinutes: time.endMinutes,
            startDate: _startDate,
            endDate: _endDate,
          ),
        );
        if (on != null) {
          return 'A one-off class for this subject is already at '
              '${Clock.format(time.startMinutes)} on '
              '${Dates.formatDayMonth(on)}, which this weekly class would land '
              'on too. They would share one attendance mark.';
        }
      }
    }
    return null;
  }

  /// Subject and start time are two thirds of the key a mark is filed under,
  /// so only those two can strand anything — a new room or end date cannot.
  int _strandedMarkCount(ClassSlot previous, ClassSlot updated) {
    if (previous.subjectId == updated.subjectId &&
        previous.startMinutes == updated.startMinutes) {
      return 0;
    }
    final List<AttendanceRecord> records =
        ref.read(timetableProvider).value?.records ?? <AttendanceRecord>[];
    return records.where(previous.covers).length;
  }

  Future<void> _save() async {
    if (_subjectId == null) {
      setState(() => _error = 'Choose a subject.');
      return;
    }
    if (_times.isEmpty) {
      setState(() => _error = 'Add at least one class time.');
      return;
    }
    for (final _ClassTime time in _times) {
      if (time.endMinutes <= time.startMinutes) {
        setState(() {
          _error = '${kWeekdayNamesLong[time.weekday - 1]}: the end time must '
              'be after the start time.';
        });
        return;
      }
    }
    final String? clash = _validateClashes();
    if (clash != null) {
      setState(() => _error = clash);
      return;
    }
    if (_endDate != null && Dates.keyOf(_endDate!) < Dates.keyOf(_startDate)) {
      setState(() => _error = 'The end date is before the start date.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final ScheduleActions schedule = ref.read(scheduleActionsProvider);

    if (_isEditing) {
      final _ClassTime time = _times.first;
      final ClassSlot previous = widget.slot!;
      // Rebuilt rather than copyWith so clearing the room actually clears it.
      final ClassSlot updated = ClassSlot(
        id: previous.id,
        subjectId: _subjectId!,
        weekday: time.weekday,
        startMinutes: time.startMinutes,
        endMinutes: time.endMinutes,
        room: time.room,
        weight: _weight,
        categoryId: _categoryId,
        startDate: _startDate,
        endDate: _endDate,
      );

      // The date is deliberately left alone: the student did attend that
      // subject on that day, and rewriting it invents one they missed.
      if (_strandedMarkCount(previous, updated) > 0) {
        await schedule.updateSlotAndMoveMarks(previous, updated);
      } else {
        await schedule.updateSlot(updated);
      }
    } else {
      final List<_ClassTime> ordered = <_ClassTime>[..._times]..sort(
          (_ClassTime a, _ClassTime b) {
            final int byDay = a.weekday.compareTo(b.weekday);
            return byDay != 0
                ? byDay
                : a.startMinutes.compareTo(b.startMinutes);
          },
        );
      for (final _ClassTime time in ordered) {
        await schedule.addSlot(
          ClassSlot(
            subjectId: _subjectId!,
            weekday: time.weekday,
            startMinutes: time.startMinutes,
            endMinutes: time.endMinutes,
            room: time.room,
            weight: _weight,
            categoryId: _categoryId,
            startDate: _startDate,
            endDate: _endDate,
          ),
        );
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bool use24Hour =
        ref.watch(settingsProvider).value?.use24HourTime ?? false;
    final String durationLabel =
        ref.watch(classLengthLabelProvider(
          (subjectId: _subjectId, categoryId: _categoryId),
        ));
    final List<int> days = _days;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SubjectPicker(
          value: _subjectId,
          onChanged: (int? id) => setState(() {
            _subjectId = id;
            // Adopt the new category's length, unless the user set an end
            // time by hand.
            if (!_durationTouched) _applyDefaultDurationToAll();
            if (!_weightTouched) _weight = _defaultWeight;
          }),
        ),
        const SizedBox(height: AppSpacing.xl),
        SectionHeader(_isEditing ? 'Day' : 'Repeats on'),
        WeekdaySelector(
          selected: days.toSet(),
          onToggle: _toggleWeekday,
        ),
        const SizedBox(height: AppSpacing.xl),
        SectionHeader(
          _isEditing ? 'Time and room' : 'Class times',
          trailing: Text(
            durationLabel,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: context.palette.textTertiary,
            ),
          ),
        ),
        for (final int weekday in days)
          _DayGroup(
            weekday: weekday,
            times: _timesOn(weekday),
            use24Hour: use24Hour,
            showHeader: !_isEditing,
            canRemove: _times.length > 1,
            onAddTime: _isEditing ? null : () => _addTimeOn(weekday),
            onPickStart: (_ClassTime t) => _pickTime(t, isStart: true),
            onPickEnd: (_ClassTime t) => _pickTime(t, isStart: false),
            onRemove: _removeTime,
          ),
        if (!_isEditing) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Each entry keeps its own time and room. Setting a start time '
            'fills the end in from the subject\'s category, and "Add another '
            'time" covers a subject that meets twice in one day.',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: context.palette.textTertiary,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        TypePicker(
          subjectId: _subjectId,
          value: _categoryId,
          onChanged: (int? id) => setState(() {
            _categoryId = id;
            if (!_durationTouched) _applyDefaultDurationToAll();
            if (!_weightTouched) _weight = _defaultWeight;
          }),
        ),
        const SizedBox(height: AppSpacing.xl),
        WeightPicker(
          value: _weight,
          onChanged: (int n) => setState(() {
            _weight = n;
            _weightTouched = true;
          }),
        ),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('Runs from'),
        Row(
          children: <Widget>[
            Expanded(
              child: FieldButton(
                label: 'First class',
                value: Dates.formatFull(_startDate),
                icon: Icons.play_arrow_rounded,
                onTap: () => _pickDate(isStart: true),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FieldButton(
                label: 'Until',
                value:
                    _endDate == null ? 'Term end' : Dates.formatFull(_endDate!),
                icon: Icons.stop_rounded,
                onTap: () => _pickDate(isStart: false),
                onClear: _endDate == null
                    ? null
                    : () => setState(() => _endDate = null),
              ),
            ),
          ],
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
          onPressed: _saving ? null : _save,
          child: Text(
            _isEditing
                ? 'Save changes'
                : (_times.length > 1
                    ? 'Add ${_times.length} weekly classes'
                    : 'Add to timetable'),
          ),
        ),
      ],
    );
  }
}

/// All the meetings on one weekday, with a control to add another.
class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.weekday,
    required this.times,
    required this.use24Hour,
    required this.showHeader,
    required this.canRemove,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onRemove,
    this.onAddTime,
  });

  final int weekday;
  final List<_ClassTime> times;
  final bool use24Hour;
  final bool showHeader;
  final bool canRemove;
  final VoidCallback? onAddTime;
  final ValueChanged<_ClassTime> onPickStart;
  final ValueChanged<_ClassTime> onPickEnd;
  final ValueChanged<_ClassTime> onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (showHeader)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.xs,
                bottom: AppSpacing.sm,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      kWeekdayNamesLong[weekday - 1].toUpperCase(),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: context.palette.textSecondary,
                      ),
                    ),
                  ),
                  if (times.length > 1)
                    Text(
                      '${times.length} classes',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: context.palette.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          for (final _ClassTime time in times)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _ClassTimeCard(
                time: time,
                use24Hour: use24Hour,
                canRemove: canRemove,
                onPickStart: () => onPickStart(time),
                onPickEnd: () => onPickEnd(time),
                onRemove: () => onRemove(time),
              ),
            ),
          if (onAddTime != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAddTime,
                icon: const Icon(Icons.add_rounded, size: 17),
                label: Text(
                  'Add another time on ${kWeekdayNamesLong[weekday - 1]}',
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A single meeting: its start and end times plus its own room.
class _ClassTimeCard extends StatelessWidget {
  const _ClassTimeCard({
    required this.time,
    required this.use24Hour,
    required this.canRemove,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onRemove,
  });

  final _ClassTime time;
  final bool use24Hour;
  final bool canRemove;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: context.palette.surfaceHigher,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: context.palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _TimeChip(
                label: Clock.format(time.startMinutes, use24Hour: use24Hour),
                onTap: onPickStart,
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Text(
                  '–',
                  style: TextStyle(
                      color: context.palette.textTertiary, fontSize: 13),
                ),
              ),
              _TimeChip(
                label: Clock.format(time.endMinutes, use24Hour: use24Hour),
                onTap: onPickEnd,
              ),
              const Spacer(),
              Text(
                Clock.formatDuration(time.endMinutes - time.startMinutes),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: context.palette.textTertiary,
                ),
              ),
              IconButton(
                onPressed: canRemove ? onRemove : null,
                icon: const Icon(Icons.close_rounded, size: 17),
                visualDensity: VisualDensity.compact,
                color: context.palette.textTertiary,
                tooltip: 'Remove this class time',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          RoomField(controller: time.roomController),
        ],
      ),
    );
  }
}

class _TimeChip extends StatelessWidget {
  const _TimeChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.palette.surface,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
