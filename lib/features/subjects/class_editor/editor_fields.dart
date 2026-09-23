import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../data/models/class_category.dart';
import '../../../data/models/room.dart';
import '../../../data/models/subject.dart';
import '../../../domain/class_weight.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';

import 'subject_editor.dart';

class DurationChip extends StatelessWidget {
  const DurationChip({
    super.key,
    required this.minutes,
    required this.selected,
    required this.onTap,
    this.label,
  });

  final int minutes;
  final bool selected;
  final VoidCallback onTap;

  /// Shown instead of the raw length, so the same chip can read "2 blocks".
  final String? label;

  @override
  Widget build(BuildContext context) {
    return OptionChip(
      label: label ?? Clock.formatDuration(minutes),
      selected: selected,
      onTap: onTap,
    );
  }
}

/// One choice among a few — a length, or which way a class repeats.
class OptionChip extends StatelessWidget {
  const OptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? context.palette.accent.withValues(alpha: 0.18)
          : context.palette.surfaceHigher,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            border: Border.all(
              color: selected
                  ? context.palette.accent.withValues(alpha: 0.7)
                  : context.palette.outline,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? context.palette.textPrimary
                  : context.palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// How many classes one occurrence counts as. Defaulting to 1 means a student
/// whose classes all count once never has to decide anything here.
class WeightPicker extends StatelessWidget {
  const WeightPicker({super.key, required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Counts as'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final int n in kClassWeights)
              OptionChip(
                label: classWeightLabel(n),
                selected: value == n,
                onTap: () => onChanged(n),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          switch (value) {
            0 => 'Held but not assessed: attending or missing one of these '
                'changes nothing. Marks already made keep what they were '
                'worth when you made them.',
            1 => 'Leave this alone unless your institution counts a longer '
                'class more than once towards attendance.',
            _ => 'Attending one of these is worth $value, and missing one '
                'costs $value. Marks already made keep what they were worth '
                'when you made them.',
          },
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: context.palette.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// Gives one class a type other than its subject's usual one. Null keeps the
/// subject's.
class TypePicker extends ConsumerWidget {
  const TypePicker({
    super.key,
    required this.subjectId,
    required this.value,
    required this.onChanged,
  });

  final int? subjectId;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TimetableData? data = ref.watch(timetableProvider).value;
    final List<ClassCategory> types =
        data?.categories ?? const <ClassCategory>[];
    if (types.isEmpty) return const SizedBox.shrink();
    final String? subjectType =
        data?.categoryFor(data.subjectById(subjectId))?.name;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Type'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            OptionChip(
              label: subjectType == null
                  ? "Subject's type"
                  : "Subject's · $subjectType",
              selected: value == null,
              onTap: () => onChanged(null),
            ),
            for (final ClassCategory type in types)
              if (type.id != null)
                OptionChip(
                  label: type.name,
                  selected: value == type.id,
                  onTap: () => onChanged(type.id),
                ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Only for a class that is not what its subject usually is, such as '
          'a lab in a lecture course. Marks already made keep the type they '
          'were made with.',
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: context.palette.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// A room entry: free text, plus one-tap chips for the rooms saved in Settings.
///
/// The chips only fill the text field in — the room is still stored on the
/// class as text, so a room that was never added to the list keeps working and
/// forgetting a room later cannot rewrite a class. Tapping the chosen room
/// clears it, which is the same rule the attendance buttons use.
class RoomField extends ConsumerWidget {
  const RoomField({super.key, required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Room> rooms =
        ref.watch(timetableProvider).value?.rooms ?? <Room>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: controller,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.place_outlined, size: 17),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 34,
              minHeight: 34,
            ),
            hintText: 'Room (optional)',
            filled: true,
            fillColor: context.palette.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.md,
            ),
          ),
        ),
        if (rooms.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (BuildContext context, TextEditingValue value, _) {
              final String current = value.text.trim().toLowerCase();
              return Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: <Widget>[
                  for (final Room room in rooms)
                    _RoomPickChip(
                      label: room.name,
                      selected: current == room.name.toLowerCase(),
                      onTap: () => controller.text =
                          current == room.name.toLowerCase() ? '' : room.name,
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

class _RoomPickChip extends StatelessWidget {
  const _RoomPickChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? context.palette.accent.withValues(alpha: 0.18)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            border: Border.all(
              color: selected
                  ? context.palette.accent.withValues(alpha: 0.7)
                  : context.palette.outline,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? context.palette.textPrimary
                  : context.palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Dropdown of existing subjects with an inline "create new" option.
class SubjectPicker extends ConsumerWidget {
  const SubjectPicker(
      {super.key, required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Subject> subjects =
        ref.watch(timetableProvider).value?.subjects ?? <Subject>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Subject'),
        if (subjects.isEmpty)
          SurfaceCard(
            color: context.palette.surfaceHigher,
            onTap: () async {
              final int? id = await showSubjectEditor(context, ref);
              if (id != null) onChanged(id);
            },
            child: Row(
              children: <Widget>[
                Icon(Icons.add_rounded, color: context.palette.accent),
                SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    'Add your first subject',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  for (final Subject subject in subjects)
                    _SubjectChip(
                      subject: subject,
                      selected: subject.id == value,
                      onTap: () => onChanged(subject.id),
                    ),
                  NewSubjectChip(
                    onTap: () async {
                      final int? id = await showSubjectEditor(context, ref);
                      if (id != null) onChanged(id);
                    },
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}

class _SubjectChip extends StatelessWidget {
  const _SubjectChip({
    required this.subject,
    required this.selected,
    required this.onTap,
  });

  final Subject subject;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = subject.color;
    return Material(
      color: selected
          ? color.withValues(alpha: 0.18)
          : context.palette.surfaceHigher,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.7)
                  : context.palette.outline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                subject.name,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? context.palette.textPrimary
                      : context.palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NewSubjectChip extends StatelessWidget {
  const NewSubjectChip({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(
                color: context.palette.accent.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.add_rounded, size: 16, color: context.palette.accent),
              SizedBox(width: 6),
              Text(
                'New',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: context.palette.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WeekdaySelector extends StatelessWidget {
  const WeekdaySelector(
      {super.key, required this.selected, required this.onToggle});

  final Set<int> selected;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (int weekday = 1; weekday <= 7; weekday++) ...<Widget>[
          Expanded(
            child: _WeekdayCell(
              weekday: weekday,
              selected: selected.contains(weekday),
              onTap: () => onToggle(weekday),
            ),
          ),
          if (weekday != 7) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _WeekdayCell extends StatelessWidget {
  const _WeekdayCell({
    required this.weekday,
    required this.selected,
    required this.onTap,
  });

  final int weekday;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? context.palette.accent : context.palette.surfaceHigher,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            border: Border.all(
              color: selected ? context.palette.accent : Colors.transparent,
            ),
          ),
          child: Text(
            kWeekdayNamesShort[weekday - 1].substring(0, 1),
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : context.palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Tappable pseudo-field used for time and date pickers.
class FieldButton extends StatelessWidget {
  const FieldButton({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.onClear,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.palette.surfaceHigher,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 16, color: context.palette.textTertiary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: context.palette.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (onClear != null)
                GestureDetector(
                  onTap: onClear,
                  child: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: context.palette.textTertiary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
