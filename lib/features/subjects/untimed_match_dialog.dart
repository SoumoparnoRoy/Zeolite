import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/attendance_record.dart';
import '../../domain/untimed_match.dart';
import '../../state/providers.dart';
import '../../widgets/undo_snack.dart';

/// After a class is saved, offers to file [subjects]' untimed marks under the
/// classes that now exist on their days. Asked rather than done, because the
/// pairing is inferred from the timetable and not something the source said.
///
/// Returns whether anything was matched, so a caller with its own Undo offer
/// knows it has been replaced.
Future<bool> offerUntimedMatch(
  BuildContext context,
  WidgetRef ref, {
  Set<int>? subjects,
}) async {
  final List<UntimedMatch> matches = <UntimedMatch>[
    for (final UntimedMatch match in ref.read(untimedMatchesProvider))
      if (subjects == null || subjects.contains(match.record.subjectId)) match,
  ];
  if (matches.isEmpty) return false;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final String classes =
      Words.plural(matches.length, 'class', 'classes');

  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      backgroundColor: context.palette.surfaceHigh,
      title: Text('Match $classes with no time?'),
      content: Text(
        matches.length == 1
            ? 'One class was imported without a time on a day that now has a '
                'class on the timetable. Matching files it under that class, '
                'so it shows as marked. Its status, weight and tag stay as '
                'they are.'
            : '$classes were imported without a time on days that now have a '
                'class on the timetable. Matching files each one under that '
                'class, so it shows as marked. Its status, weight and tag stay '
                'as they are.',
        style: const TextStyle(height: 1.4),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Match them'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  final ActionCore core = ref.read(actionCoreProvider);
  final int count =
      await ref.read(attendanceActionsProvider).matchUntimed(matches);
  showUndoSnack(messenger, core, matchedMessage(count));
  return true;
}

String matchedMessage(int count) =>
    'Matched ${Words.plural(count, 'class', 'classes')} to the timetable';

/// Where a new weekly class for [subjectId] should start. A subject already
/// holding untimed marks has had classes all term, and a rule starting today
/// would leave those marks with nothing to be matched to.
DateTime firstClassFor(WidgetRef ref, int? subjectId, DateTime otherwise) {
  final DateTime? termStart = ref.read(settingsProvider).value?.semesterStart;
  if (subjectId == null ||
      termStart == null ||
      Dates.keyOf(termStart) >= Dates.keyOf(otherwise)) {
    return otherwise;
  }
  final bool untimed = ref.read(timetableProvider).value?.records.any(
            (AttendanceRecord r) =>
                r.subjectId == subjectId &&
                !AttendanceRecord.isTimed(r.startMinutes),
          ) ??
      false;
  return untimed ? Dates.dayOf(termStart) : otherwise;
}
