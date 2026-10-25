import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/words.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/subject.dart';
import '../../state/providers.dart';

/// Asks before a subject is deleted, naming what goes with it.
///
/// Shared by every place a subject can be deleted from, so none of them
/// promises less is lost than the others.
Future<bool> confirmSubjectDelete(
  BuildContext context,
  Subject subject,
  TimetableData? data,
) async {
  final int? id = subject.id;
  int slots = 0;
  int extras = 0;
  int marks = 0;
  if (data != null && id != null) {
    for (final ClassSlot slot in data.slots) {
      if (slot.subjectId == id) slots++;
    }
    for (final ExtraClass extra in data.extras) {
      if (extra.subjectId == id) extras++;
    }
    for (final AttendanceRecord record in data.records) {
      if (record.subjectId == id) marks++;
    }
  }

  final List<String> losses = <String>[
    if (slots > 0) slots == 1 ? '1 weekly class' : '$slots weekly classes',
    if (extras > 0) extras == 1 ? '1 one-off class' : '$extras one-off classes',
    if (marks > 0) marks == 1 ? '1 attendance mark' : '$marks attendance marks',
    // A carried balance is not a record, so counting only marks would offer
    // to delete a subject's whole history under "nothing else is lost".
    if (subject.priorHeld > 0)
      '${subject.priorAttended} of ${subject.priorHeld} carried in',
    if (subject.priorCancelled > 0)
      '${Words.plural(subject.priorCancelled, 'cancelled class', 'cancelled classes')} carried in',
  ];

  final String message = losses.isEmpty
      ? 'Nothing is recorded against it yet, so nothing else is lost.'
      : '${subject.name} has ${_joinNaturally(losses)}. Deleting the subject '
          'removes all of it.';

  final OverlayState? overlay =
      Navigator.of(context, rootNavigator: true).overlay;
  ModalRoute<Object?>? dialog;
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      dialog ??= ModalRoute.of(context);
      return AlertDialog(
        title: Text('Delete ${subject.name}?'),
        content: Text(message, style: const TextStyle(height: 1.4)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style:
                TextButton.styleFrom(foregroundColor: context.palette.absent),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  if (overlay != null && dialog != null) _coverWhileClosing(overlay, dialog!);
  return confirmed ?? false;
}

/// A closing dialog's barrier stops taking taps as soon as it starts to fade,
/// so the second tap of a double tap on *Delete* or *Cancel* would land on
/// whatever is underneath: another subject's row, or a button in the sheet the
/// dialog came from. This covers the screen until the dialog has gone, however
/// it was closed.
///
/// [TransitionRoute.completed] fires when the route is disposed, including
/// when it is removed before its animation finishes. The timer is a backstop so
/// the cover can never outlast a dialog that somehow never completes.
void _coverWhileClosing(OverlayState overlay, ModalRoute<Object?> dialog) {
  if (!overlay.mounted) return;
  final OverlayEntry cover = OverlayEntry(
    builder: (BuildContext context) => const ModalBarrier(dismissible: false),
  );
  overlay.insert(cover);
  bool removed = false;
  late final Timer backstop;
  void remove() {
    if (removed) return;
    removed = true;
    backstop.cancel();
    cover.remove();
    cover.dispose();
  }

  backstop = Timer(const Duration(seconds: 1), remove);
  dialog.completed.whenComplete(remove);
}

/// "a, b and c" — reads like a sentence rather than a list of counts.
String _joinNaturally(List<String> parts) {
  if (parts.length == 1) return parts.first;
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}
