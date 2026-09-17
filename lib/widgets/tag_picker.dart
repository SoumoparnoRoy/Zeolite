import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../data/models/tag.dart';
import 'common.dart';

/// Asks which tag to put on a mark. Returns the tapped tag's id, or null when
/// the sheet was dismissed without choosing.
///
/// There is deliberately no "No tag" row: tapping the tag a mark already has
/// clears it, which is the rule the three status buttons already taught. The
/// caller passes the result to `AttendanceActions.setTagAt`, which does the
/// toggling — so the rule has one implementation rather than one per surface.
Future<int?> showTagPicker(
  BuildContext context, {
  required List<Tag> tags,
  int? selected,
}) {
  return showAppSheet<int>(
    context: context,
    title: 'Tag this class',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          selected == null
              ? 'Optional. The Present or Absent mark stays exactly as it is.'
              : 'Tap the current tag to remove it.',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: context.palette.textTertiary,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final Tag tag in tags)
              _PickerChip(
                label: tag.name,
                selected: tag.id == selected,
                onTap: () => Navigator.of(context).pop(tag.id),
              ),
          ],
        ),
      ],
    ),
  );
}

class _PickerChip extends StatelessWidget {
  const _PickerChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color accent = context.palette.cyan;
    return Material(
      color: selected
          ? accent.withValues(alpha: 0.16)
          : context.palette.surfaceHigher,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(
              color:
                  selected ? accent.withValues(alpha: 0.6) : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                selected ? Icons.check_rounded : Icons.sell_outlined,
                size: 15,
                color: selected ? accent : context.palette.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? accent : context.palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
