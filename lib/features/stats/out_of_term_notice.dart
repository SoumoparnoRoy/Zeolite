import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_stats.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';

/// Names the marks that fall outside the term and offers the ways out of
/// it. Nothing here deletes anything — two of the three are views of the same
/// marks, and the third edits dates that can be edited back.
class OutOfTermNotice extends ConsumerWidget {
  const OutOfTermNotice(
      {super.key, required this.marks, required this.settings});

  final OutOfTermMarks marks;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    final Color accent = p.warning;
    final bool counted = settings.countOutsideTerm;
    final String span = marks.earliest == null || marks.latest == null
        ? ''
        : ' (${Dates.formatFull(marks.earliest!)} – '
            '${Dates.formatFull(marks.latest!)})';

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.event_busy_outlined, size: 18, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${Words.plural(marks.count, 'mark')} outside your term '
                  'dates$span. ${counted ? 'They are counted below.' : 'They '
                      'are not counted below.'}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          // Wrap rather than a Row: the two labels are long enough to collide
          // on a phone width, and this screen has to hold up on both.
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 4),
            child: Wrap(
              spacing: 4,
              children: <Widget>[
                TextButton(
                  onPressed: () => ref
                      .read(settingsProvider.notifier)
                      .setCountOutsideTerm(!counted),
                  child: Text(counted ? 'Leave them out' : 'Count them'),
                ),
                TextButton(
                  onPressed: () => _widen(context, ref),
                  child: const Text('Widen term'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Moves whichever end of the term has marks beyond it. Confirmed first,
  /// because the dates drive recurrence and projections app-wide.
  Future<void> _widen(BuildContext context, WidgetRef ref) async {
    final (DateTime, DateTime)? widened = marks.widenedTerm(settings);
    if (widened == null) return;
    final (DateTime start, DateTime end) = widened;

    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Widen the term?'),
        content: Text(
          'The term becomes ${Dates.formatFull(start)} – '
          '${Dates.formatFull(end)}, so these marks fall inside it. '
          'Recurring classes and the figures that project forward all follow '
          'the term dates, so they change too.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Widen'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await ref.read(settingsProvider.notifier).setTerm(start, end);
  }
}
