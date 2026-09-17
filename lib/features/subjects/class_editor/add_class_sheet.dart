import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_theme.dart';
import '../../../widgets/common.dart';

import 'extra_class_editor.dart';
import 'slot_editor.dart';

/// Asks whether the new class repeats weekly or happens once, then opens the
/// matching editor.
Future<void> showAddClassSheet(
  BuildContext context,
  WidgetRef ref, {
  DateTime? initialDate,
}) async {
  final _AddKind? kind = await showAppSheet<_AddKind>(
    context: context,
    title: 'Add a class',
    child: Column(
      children: <Widget>[
        _ChoiceTile(
          icon: Icons.repeat_rounded,
          title: 'Repeats every week',
          subtitle:
              'Pick the days and time. It appears every week from the start date onwards.',
          onTap: () => Navigator.of(context).pop(_AddKind.recurring),
        ),
        const SizedBox(height: AppSpacing.md),
        _ChoiceTile(
          icon: Icons.event_rounded,
          title: 'One-off class',
          subtitle: 'A single make-up lecture, extra lab or rescheduled slot.',
          onTap: () => Navigator.of(context).pop(_AddKind.oneOff),
        ),
      ],
    ),
  );

  if (kind == null || !context.mounted) return;
  if (kind == _AddKind.recurring) {
    await showSlotEditor(context, ref, initialDate: initialDate);
  } else {
    await showExtraClassEditor(context, ref, initialDate: initialDate);
  }
}

enum _AddKind { recurring, oneOff }

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      color: context.palette.surfaceHigher,
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.palette.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
            child: Icon(icon, color: context.palette.accent, size: 22),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
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
