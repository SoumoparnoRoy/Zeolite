import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../core/time_picker.dart';
import '../../../data/models/attendance_record.dart';
import '../../../data/models/class_category.dart';
import '../../../data/models/extra_class.dart';
import '../../../domain/class_clash.dart';
import '../../../domain/class_weight.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';

import 'editor_fields.dart';

Future<void> showExtraClassEditor(
  BuildContext context,
  WidgetRef ref, {
  DateTime? initialDate,
  ExtraClass? extra,
}) {
  return showAppSheet<void>(
    context: context,
    title: extra == null ? 'One-off class' : 'Edit one-off class',
    child: _ExtraClassForm(initialDate: initialDate, extra: extra),
  );
}

class _ExtraClassForm extends ConsumerStatefulWidget {
  const _ExtraClassForm({this.initialDate, this.extra});

  final DateTime? initialDate;
  final ExtraClass? extra;

  @override
  ConsumerState<_ExtraClassForm> createState() => _ExtraClassFormState();
}

class _ExtraClassFormState extends ConsumerState<_ExtraClassForm> {
  int? _subjectId;
  late DateTime _date;
  int _start = 9 * 60;
  int _end = 10 * 60;
  late final TextEditingController _room;
  String? _error;
  bool _saving = false;

  /// See the weekly form's `_weight`.
  int _weight = 1;

  /// See the weekly form: only a hand-set end time pins the length.
  bool _durationTouched = false;

  bool _weightTouched = false;

  bool get _isEditing => widget.extra != null;

  /// See the weekly form's `_categoryId`.
  int? _categoryId;

  ClassCategory? get _ownType =>
      ref.read(timetableProvider).value?.categoryById(_categoryId);

  int get _defaultDuration =>
      _ownType?.defaultDurationMinutes ??
      ref.read(defaultDurationProvider(_subjectId));

  int get _defaultWeight => _ownType == null
      ? ref.read(defaultWeightProvider(_subjectId))
      : weightFor(_ownType);

  @override
  void initState() {
    super.initState();
    final ExtraClass? extra = widget.extra;
    _date = extra?.date ?? widget.initialDate ?? Dates.today();
    _room = TextEditingController(text: extra?.room ?? '');
    if (extra != null) {
      _subjectId = extra.subjectId;
      _categoryId = extra.categoryId;
      _start = extra.startMinutes;
      _end = extra.endMinutes;
      _weight = extra.weight;
      // An existing class already has the length its owner meant, so opening
      // the form must not re-length it from the category.
      _durationTouched = true;
      _weightTouched = true;
    } else {
      _weight = _defaultWeight;
    }
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
      final int value = Clock.toMinutes(picked.hour, picked.minute);
      if (isStart) {
        final int duration =
            _durationTouched ? _end - _start : _defaultDuration;
        _start = value;
        _end = Clock.endFromStart(value, duration);
      } else {
        _durationTouched = true;
        _end = value;
      }
    });
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(DateTime.now().year - 2),
      lastDate: DateTime(DateTime.now().year + 3),
    );
    if (picked == null || !mounted) return;
    setState(() => _date = Dates.dayOf(picked));
  }

  /// A one-off is a single occurrence, so its date is part of the key too:
  /// moving it to another day strands the mark exactly as changing the subject
  /// does.
  bool _rekeys(ExtraClass previous, ExtraClass updated) =>
      previous.subjectId != updated.subjectId ||
      previous.startMinutes != updated.startMinutes ||
      Dates.keyOf(previous.date) != Dates.keyOf(updated.date);

  bool _hasMark(ExtraClass extra) {
    final List<AttendanceRecord> records =
        ref.read(timetableProvider).value?.records ?? <AttendanceRecord>[];
    for (final AttendanceRecord record in records) {
      if (record.subjectId == extra.subjectId &&
          record.startMinutes == extra.startMinutes &&
          Dates.keyOf(record.date) == Dates.keyOf(extra.date)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _save() async {
    if (_subjectId == null) {
      setState(() => _error = 'Choose a subject.');
      return;
    }
    if (_end <= _start) {
      setState(() => _error = 'The end time must be after the start time.');
      return;
    }

    // Rebuilt rather than copyWith so clearing the room actually clears it.
    final ExtraClass value = ExtraClass(
      id: widget.extra?.id,
      subjectId: _subjectId!,
      date: _date,
      startMinutes: _start,
      endMinutes: _end,
      room: _room.text.trim().isEmpty ? null : _room.text.trim(),
      weight: _weight,
      categoryId: _categoryId,
      note: widget.extra?.note,
    );

    final TimetableData? data = ref.read(timetableProvider).value;
    if (data != null &&
        ClassClash.forOneOff(
          slots: data.slots,
          extras: data.extras,
          proposed: value,
        )) {
      setState(() {
        _error = 'This subject already has a class at '
            '${Clock.format(_start)} on ${Dates.formatDayMonth(_date)}. '
            'Attendance is recorded per subject and start time, so the two '
            'would share one mark.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final ScheduleActions schedule = ref.read(scheduleActionsProvider);
    if (_isEditing) {
      final ExtraClass previous = widget.extra!;
      if (_hasMark(previous) && _rekeys(previous, value)) {
        await schedule.updateExtraClassAndMoveMarks(previous, value);
      } else {
        await schedule.updateExtraClass(value);
      }
    } else {
      await schedule.addExtraClass(value);
    }

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
        SubjectPicker(
          value: _subjectId,
          onChanged: (int? id) => setState(() {
            _subjectId = id;
            if (!_durationTouched) {
              _end = Clock.endFromStart(_start, _defaultDuration);
            }
            if (!_weightTouched) _weight = _defaultWeight;
          }),
        ),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('When'),
        FieldButton(
          label: 'Date',
          value: '${Dates.weekdayLong(_date)}, ${Dates.formatFull(_date)}',
          icon: Icons.event_rounded,
          onTap: _pickDate,
        ),
        const SizedBox(height: AppSpacing.md),
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
        const SizedBox(height: AppSpacing.xl),
        TypePicker(
          subjectId: _subjectId,
          value: _categoryId,
          onChanged: (int? id) => setState(() {
            _categoryId = id;
            if (!_durationTouched) {
              _end = Clock.endFromStart(_start, _defaultDuration);
            }
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
          child: Text(_isEditing ? 'Save changes' : 'Add one-off class'),
        ),
      ],
    );
  }
}
