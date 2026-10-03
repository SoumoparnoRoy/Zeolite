import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../data/models/subject.dart';
import '../../../state/providers.dart';
import '../../../widgets/common.dart';
import 'editor_fields.dart';
import 'subject_editor.dart';

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
              final int? id = await showSubjectEditor(context);
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
                      final int? id = await showSubjectEditor(context);
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
                  fontSize: AppType.titleSmall,
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
