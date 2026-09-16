import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import 'common.dart';

/// Whether a course's lab joins its lectures or becomes a subject of its own.
///
/// Shared by both imports that can split a course, so the two read the same.
/// [source] names what the weights come from — the file, the sheet.
class CourseSplitChoice extends StatelessWidget {
  const CourseSplitChoice({
    super.key,
    required this.grouped,
    required this.source,
    required this.onChanged,
  });

  final bool grouped;
  final String source;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final bool option in const <bool>[true, false]) ...<Widget>[
          SurfaceCard(
            onTap: () => onChanged(option),
            child: Row(
              children: <Widget>[
                Icon(
                  option == grouped
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: option == grouped ? p.accent : p.textFaint,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        option
                            ? 'One subject per course'
                            : 'Lecture and lab kept apart',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        option
                            ? 'The lab sits inside its course and counts for '
                                'as much as the $source says — a two-period '
                                'lab twice.'
                            : 'The lab becomes its own subject with its own '
                                'target, and every class counts once.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: p.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}
