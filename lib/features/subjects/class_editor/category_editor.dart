import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../data/models/class_category.dart';
import '../../../data/models/subject.dart';
import '../../../domain/day_grid.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';

import 'editor_fields.dart';

/// Create or edit a class category. Returns its id on save.
Future<int?> showCategoryEditor(
  BuildContext context,
  WidgetRef ref, {
  ClassCategory? category,
}) {
  return showAppSheet<int>(
    context: context,
    title: category == null ? 'New category' : 'Edit category',
    child: _CategoryForm(category: category),
  );
}

class _CategoryForm extends ConsumerStatefulWidget {
  const _CategoryForm({this.category});

  final ClassCategory? category;

  @override
  ConsumerState<_CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends ConsumerState<_CategoryForm> {
  late final TextEditingController _name;
  late int _minutes;
  late int _weight;
  String? _error;
  bool _saving = false;

  /// Held until save so the sheet can be abandoned, and so a new category can
  /// be filled in before it has an id.
  final Set<int> _subjectIds = <int>{};

  /// Lengths a timetable actually uses, so the common case is one tap.
  static const List<int> _presets = <int>[30, 45, 50, 60, 90, 120, 180];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.category?.name ?? '');
    _minutes = widget.category?.defaultDurationMinutes ?? 60;
    _weight = widget.category?.weight ?? 1;

    final int? id = widget.category?.id;
    if (id != null) {
      for (final Subject subject
          in ref.read(timetableProvider).value?.subjects ?? const <Subject>[]) {
        if (subject.categoryId == id && subject.id != null) {
          _subjectIds.add(subject.id!);
        }
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the category a name.');
      return;
    }

    final List<ClassCategory> existing =
        ref.read(timetableProvider).value?.categories ?? <ClassCategory>[];
    for (final ClassCategory other in existing) {
      if (other.id == widget.category?.id) continue;
      if (other.name.toLowerCase() == name.toLowerCase()) {
        setState(() => _error = 'You already have a category called "$name".');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final SubjectActions subjects = ref.read(subjectActionsProvider);
    int? id = widget.category?.id;
    if (id == null) {
      id = await subjects.addCategory(
        ClassCategory(
          name: name,
          defaultDurationMinutes: _minutes,
          weight: _weight,
        ),
      );
    } else {
      await subjects.updateCategory(
        ClassCategory(
          id: id,
          name: name,
          defaultDurationMinutes: _minutes,
          weight: _weight,
          createdAt: widget.category?.createdAt,
        ),
      );
    }

    await _applyMembership(subjects, id);

    if (!mounted) return;
    Navigator.of(context).pop(id);
  }

  /// Writes only the subjects that changed: `updated_at` drives sync, so a
  /// rewrite of one already filed here would be a change nobody made.
  Future<void> _applyMembership(SubjectActions subjects, int id) async {
    for (final Subject subject
        in ref.read(timetableProvider).value?.subjects ?? const <Subject>[]) {
      final int? subjectId = subject.id;
      if (subjectId == null) continue;

      final bool wanted = _subjectIds.contains(subjectId);
      final bool held = subject.categoryId == id;
      if (wanted == held) continue;

      await subjects.updateSubject(
        wanted
            ? subject.copyWith(categoryId: id)
            : subject.copyWith(clearCategory: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final DayGrid grid = ref.watch(dayGridProvider);
    // Six blocks covers any single class anyone actually sits through, and the
    // slider below still reaches anything unusual.
    final int maxBlocks = grid.blockCount < 6 ? grid.blockCount : 6;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _name,
          autofocus: widget.category == null,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Category name',
            hintText: 'e.g. Lecture, Practical, Tutorial',
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        SectionHeader(
          grid.isConfigured ? 'How many blocks' : 'Default class length',
        ),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            // With a block length set, blocks are the unit that matters — a lab
            // is "two lectures long", whatever a lecture happens to be.
            if (grid.isConfigured)
              for (int blocks = 1; blocks <= maxBlocks; blocks++)
                DurationChip(
                  minutes: blocks * grid.blockMinutes,
                  label: '$blocks ${blocks == 1 ? 'block' : 'blocks'}',
                  selected: _minutes == blocks * grid.blockMinutes,
                  onTap: () =>
                      setState(() => _minutes = blocks * grid.blockMinutes),
                )
            else
              for (final int preset in _presets)
                DurationChip(
                  minutes: preset,
                  selected: preset == _minutes,
                  onTap: () => setState(() => _minutes = preset),
                ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: <Widget>[
            Expanded(
              child: Slider(
                value: _minutes.toDouble().clamp(15, 300),
                min: 15,
                max: 300,
                divisions: 57,
                label: Clock.formatDuration(_minutes),
                onChanged: (double v) =>
                    setState(() => _minutes = (v / 5).round() * 5),
              ),
            ),
            SizedBox(
              width: 62,
              child: Text(
                Clock.formatDuration(_minutes),
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: context.palette.accent,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          grid.isConfigured && !grid.isWholeBlocks(_minutes)
              // Silently rounding would move a length the user chose on
              // purpose, so it is reported instead.
              ? '${Clock.formatDuration(_minutes)} is not a whole number of '
                  '${Clock.formatDuration(grid.blockMinutes)} blocks, so this '
                  'category will not line up with the grid.'
              : 'Picking a start time for a class in this category fills the '
                  'end time in automatically.',
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: context.palette.textTertiary,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        WeightPicker(
          value: _weight,
          onChanged: (int n) => setState(() => _weight = n),
        ),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('Subjects in this category'),
        _CategorySubjects(
          chosen: _subjectIds,
          categoryId: widget.category?.id,
          onToggle: (int id) => setState(() {
            if (!_subjectIds.remove(id)) _subjectIds.add(id);
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
          child: Text(
            widget.category == null ? 'Create category' : 'Save changes',
          ),
        ),
      ],
    );
  }
}

/// Every subject, with the ones in this category ticked.
///
/// A subject is in one category at a time, so picking one filed elsewhere
/// moves it — said on the row, because the other category quietly losing a
/// subject is the surprise worth a line.
class _CategorySubjects extends ConsumerWidget {
  const _CategorySubjects({
    required this.chosen,
    required this.categoryId,
    required this.onToggle,
  });

  final Set<int> chosen;
  final int? categoryId;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TimetableData? data = ref.watch(timetableProvider).value;
    final List<Subject> subjects = data?.subjects ?? const <Subject>[];
    if (subjects.isEmpty) {
      return Text(
        'No subjects yet. Add one and it can be filed here.',
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: context.palette.textTertiary,
        ),
      );
    }

    final Map<int, String> categoryNames = <int, String>{
      for (final ClassCategory c in data?.categories ?? const <ClassCategory>[])
        if (c.id != null) c.id!: c.name,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final Subject subject in subjects)
          if (subject.id != null)
            _SubjectToggle(
              subject: subject,
              selected: chosen.contains(subject.id),
              // Only when it is somewhere else, and not where it already is.
              heldBy:
                  subject.categoryId == null || subject.categoryId == categoryId
                      ? null
                      : categoryNames[subject.categoryId],
              onTap: () => onToggle(subject.id!),
            ),
      ],
    );
  }
}

class _SubjectToggle extends StatelessWidget {
  const _SubjectToggle({
    required this.subject,
    required this.selected,
    required this.heldBy,
    required this.onTap,
  });

  final Subject subject;
  final bool selected;
  final String? heldBy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: <Widget>[
            Icon(
              selected
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 22,
              color: selected ? p.accent : p.textTertiary,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                subject.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            if (heldBy != null)
              Text(
                selected ? 'moved from $heldBy' : 'in $heldBy',
                style: TextStyle(fontSize: 11.5, color: p.textTertiary),
              ),
          ],
        ),
      ),
    );
  }
}
