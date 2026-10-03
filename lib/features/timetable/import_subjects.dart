import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../data/models/subject.dart';
import '../../widgets/common.dart';

/// One subject the sheet names, and which subject its classes will join.
class ImportSubjectRow extends StatelessWidget {
  const ImportSubjectRow({
    super.key,
    required this.name,
    required this.target,
    required this.onTap,
  });

  final String name;

  /// Null makes a new subject of [name].
  final Subject? target;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: SurfaceCard(
        onTap: onTap,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: AppType.titleSmall,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    target == null ? 'New subject' : 'Added to ${target!.name}',
                    style: TextStyle(
                        fontSize: AppType.bodySmall, color: p.textTertiary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Asks which subject [sheetName]'s classes join. Null when dismissed; a
/// record holding a null id when the answer is a new subject.
Future<({int? id})?> pickImportSubject(
  BuildContext context, {
  required String sheetName,
  required List<Subject> subjects,
  required int? current,
}) {
  return showAppSheet<({int? id})>(
    context: context,
    title: sheetName,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Option(
          label: 'New subject',
          detail: 'Named $sheetName',
          selected: current == null,
          onTap: () => Navigator.of(context).pop((id: null)),
        ),
        for (final Subject subject in subjects)
          _Option(
            label: subject.name,
            detail: subject.code,
            selected: subject.id == current,
            onTap: () => Navigator.of(context).pop((id: subject.id)),
          ),
      ],
    ),
  );
}

class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: AppType.titleMedium,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (detail != null && detail!.isNotEmpty)
                    Text(
                      detail!,
                      style: TextStyle(
                          fontSize: AppType.bodySmall, color: p.textTertiary),
                    ),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_rounded, color: p.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
