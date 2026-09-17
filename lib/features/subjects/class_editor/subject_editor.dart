import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../core/date_utils.dart';
import '../../../data/models/class_category.dart';
import '../../../data/models/subject.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';

import 'category_editor.dart';
import 'editor_fields.dart';

/// Create or edit a subject. Returns the subject id on save.
Future<int?> showSubjectEditor(
  BuildContext context,
  WidgetRef ref, {
  Subject? subject,
}) {
  return showAppSheet<int>(
    context: context,
    title: subject == null ? 'New subject' : 'Edit subject',
    child: _SubjectForm(subject: subject),
  );
}

class _SubjectForm extends ConsumerStatefulWidget {
  const _SubjectForm({this.subject});

  final Subject? subject;

  @override
  ConsumerState<_SubjectForm> createState() => _SubjectFormState();
}

class _SubjectFormState extends ConsumerState<_SubjectForm> {
  late final TextEditingController _name;
  late final TextEditingController _code;
  late final TextEditingController _teacher;
  late int _color;
  int? _categoryId;
  late bool _overrideTarget;
  late double _target;
  late final TextEditingController _priorHeld;
  late final TextEditingController _priorAttended;
  late final TextEditingController _expectedTotal;
  late bool _carryBalance;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final Subject? s = widget.subject;
    _name = TextEditingController(text: s?.name ?? '');
    _code = TextEditingController(text: s?.code ?? '');
    _teacher = TextEditingController(text: s?.teacher ?? '');
    _color = s?.colorValue ?? AppColors.subjectPalette.first;
    _categoryId = s?.categoryId;
    _overrideTarget = s?.targetPercent != null;
    _target = s?.targetPercent ?? 75;
    _priorHeld = TextEditingController(text: _digits(s?.priorHeld));
    _priorAttended = TextEditingController(text: _digits(s?.priorAttended));
    _expectedTotal = TextEditingController(text: _digits(s?.expectedTotal));
    _carryBalance = (s?.priorHeld ?? 0) > 0 || s?.expectedTotal != null;
  }

  /// Empty rather than "0", so an untouched field reads as unanswered.
  static String _digits(int? value) =>
      value == null || value == 0 ? '' : '$value';

  int? _read(TextEditingController c) {
    final String text = c.text.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _teacher.dispose();
    _priorHeld.dispose();
    _priorAttended.dispose();
    _expectedTotal.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the subject a name.');
      return;
    }
    final int held = _carryBalance ? (_read(_priorHeld) ?? 0) : 0;
    final int attended = _carryBalance ? (_read(_priorAttended) ?? 0) : 0;
    final int? total = _carryBalance ? _read(_expectedTotal) : null;
    if (attended > held) {
      setState(() => _error = 'Attended cannot be more than held.');
      return;
    }
    if (total != null && total < held) {
      setState(() => _error = 'The term total is less than what is held.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final Subject value = Subject(
      id: widget.subject?.id,
      name: name,
      code: _code.text.trim().isEmpty ? null : _code.text.trim(),
      teacher: _teacher.text.trim().isEmpty ? null : _teacher.text.trim(),
      colorValue: _color,
      targetPercent: _overrideTarget ? _target : null,
      categoryId: _categoryId,
      createdAt: widget.subject?.createdAt,
      priorHeld: held,
      priorAttended: attended,
      expectedTotal: total,
    );

    final TimetableActions actions = ref.read(actionsProvider);
    int? id = widget.subject?.id;
    if (id == null) {
      id = await actions.addSubject(value);
    } else {
      await actions.updateSubject(value);
    }

    if (!mounted) return;
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _name,
          autofocus: widget.subject == null,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Subject name',
            hintText: 'e.g. Thermodynamics',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  hintText: 'e.g. CS201',
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: TextField(
                controller: _teacher,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Professor',
                  hintText: 'Optional',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        _CategoryPicker(
          value: _categoryId,
          onChanged: (int? id) => setState(() => _categoryId = id),
        ),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('Colour'),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: <Widget>[
            for (final int value in AppColors.subjectPalette)
              _ColorDot(
                value: value,
                selected: value == _color,
                onTap: () => setState(() => _color = value),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        SwitchListTile.adaptive(
          value: _overrideTarget,
          onChanged: (bool v) => setState(() => _overrideTarget = v),
          contentPadding: EdgeInsets.zero,
          title: const Text('Custom attendance target'),
          subtitle: Text(
            _overrideTarget
                ? 'This subject needs ${_target.round()}%'
                : 'Uses your global target',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        if (_overrideTarget)
          Slider(
            value: _target,
            min: 40,
            max: 100,
            divisions: 60,
            label: '${_target.round()}%',
            onChanged: (double v) => setState(() => _target = v),
          ),
        const SizedBox(height: AppSpacing.xl),
        SwitchListTile.adaptive(
          value: _carryBalance,
          onChanged: (bool v) => setState(() => _carryBalance = v),
          contentPadding: EdgeInsets.zero,
          title: const Text('Already attended'),
          subtitle: const Text(
            'Classes counted before this app, so the percentage is right from '
            'the first mark',
            style: TextStyle(fontSize: 12.5),
          ),
        ),
        if (_carryBalance) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: _CountField(
                  controller: _priorHeld,
                  label: 'Held',
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _CountField(
                  controller: _priorAttended,
                  label: 'Attended',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _CountField(
            controller: _expectedTotal,
            label: 'Classes all term',
            // Without this the app can only project from the timetable, which
            // says nothing for a subject that has no classes on it.
            helper: 'Optional. Lets the app say what is still to come.',
          ),
        ],
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
          child: Text(widget.subject == null ? 'Create subject' : 'Save'),
        ),
      ],
    );
  }
}

class _CountField extends StatelessWidget {
  const _CountField({
    required this.controller,
    required this.label,
    this.helper,
  });

  final TextEditingController controller;
  final String label;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: InputDecoration(
        labelText: label,
        hintText: '0',
        helperText: helper,
        helperMaxLines: 2,
      ),
    );
  }
}

/// Recolour a subject without opening the whole form — one tap, saved straight
/// away. Used by the long-press and the overflow menu on the Subjects screen.
Future<void> showSubjectColorPicker(
  BuildContext context,
  WidgetRef ref,
  Subject subject,
) {
  return showAppSheet<void>(
    context: context,
    title: subject.name,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Colour'),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: <Widget>[
            for (final int value in AppColors.subjectPalette)
              _ColorDot(
                value: value,
                selected: value == subject.colorValue,
                onTap: () async {
                  Navigator.of(context).pop();
                  if (value == subject.colorValue) return;
                  await ref
                      .read(actionsProvider)
                      .updateSubject(subject.copyWith(colorValue: value));
                },
              ),
          ],
        ),
      ],
    ),
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = Color(value);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 1 : 0.35),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 20, color: Colors.white)
            : null,
      ),
    );
  }
}

/// Chooses which category a subject belongs to, with an inline "new category"
/// escape hatch so the flow is never blocked by missing setup.
class _CategoryPicker extends ConsumerWidget {
  const _CategoryPicker({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<ClassCategory> categories =
        ref.watch(timetableProvider).value?.categories ?? <ClassCategory>[];
    final int fallback =
        ref.watch(settingsProvider).value?.defaultClassDurationMinutes ?? 60;

    ClassCategory? selected;
    for (final ClassCategory category in categories) {
      if (category.id == value) selected = category;
    }
    final String selectedLabel = selected == null
        ? 'Without a category, new classes default to '
            '${Clock.formatDuration(fallback)}.'
        : '${selected.name} classes default to ${selected.durationLabel}.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Category'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            _CategoryChip(
              label: 'None',
              detail: Clock.formatDuration(fallback),
              selected: value == null,
              onTap: () => onChanged(null),
            ),
            for (final ClassCategory category in categories)
              _CategoryChip(
                label: category.name,
                detail: category.durationLabel,
                selected: category.id == value,
                onTap: () => onChanged(category.id),
              ),
            NewSubjectChip(
              onTap: () async {
                final int? id = await showCategoryEditor(context, ref);
                if (id != null) onChanged(id);
              },
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          selectedLabel,
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

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? context.palette.accent.withValues(alpha: 0.18)
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
                  ? context.palette.accent.withValues(alpha: 0.7)
                  : context.palette.outline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? context.palette.textPrimary
                      : context.palette.textSecondary,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                detail,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
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
