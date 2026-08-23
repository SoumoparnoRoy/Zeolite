import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/class_category.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/subject.dart';
import '../../domain/attendance_stats.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';
import 'class_editor_sheets.dart';

/// Every subject in one place: add, edit, recolour and delete.
///
/// Pushed from Settings. The rest of the app edits subjects incidentally — from
/// a class editor or a stats card — so this is the one screen that treats them
/// as the list they are.
class SubjectsScreen extends ConsumerWidget {
  const SubjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TimetableData? data = ref.watch(timetableProvider).value;
    // Already ordered by name from the repository.
    final List<Subject> subjects = data?.subjects ?? <Subject>[];
    final int weekly = data?.slots.length ?? 0;

    return PushScaffold(
      title: 'Subjects',
      subtitle: subjects.isEmpty
          ? null
          : '${subjects.length} ${subjects.length == 1 ? 'course' : 'courses'}'
              ' · $weekly weekly ${weekly == 1 ? 'class' : 'classes'}',
      floatingActionButton: subjects.isEmpty
          ? null
          : GradientFab(
              label: 'Add subject',
              onPressed: () => showSubjectEditor(context, ref),
            ),
      slivers: <Widget>[
        if (subjects.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 40, bottom: 60),
              child: EmptyState(
                icon: Icons.school_outlined,
                title: 'No subjects yet',
                message: 'Add the courses you are taking. Classes hang off a '
                    'subject, and your attendance is tracked per subject.',
                action: FilledButton.icon(
                  onPressed: () => showSubjectEditor(context, ref),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add your first subject'),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
            sliver: SliverList.separated(
              itemCount: subjects.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (BuildContext context, int index) =>
                  _SubjectRow(subject: subjects[index]),
            ),
          ),
      ],
    );
  }
}

enum _SubjectAction { edit, colour, delete }

/// Counting for a subject that has no classes on the timetable — a portal that
/// reports totals is the only record it has, so a class is recorded by moving
/// the balance rather than by marking an occurrence that does not exist.
///
/// Both buttons only ever add. A mis-tap is corrected by opening the subject
/// and typing the two numbers, which is exact and one tap away, rather than by
/// a second pair of controls that would double the width of this row.
class _BalanceCounter extends ConsumerWidget {
  const _BalanceCounter({required this.subject});

  final Subject subject;

  Future<void> _add(WidgetRef ref, {required bool attended}) {
    return ref.read(actionsProvider).updateSubject(
          subject.copyWith(
            priorHeld: subject.priorHeld + 1,
            priorAttended: subject.priorAttended + (attended ? 1 : 0),
          ),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '${subject.priorAttended} of ${subject.priorHeld} attended',
            style: monoStyle(color: p.textTertiary, size: 10),
          ),
        ),
        _CountButton(
          icon: Icons.check_rounded,
          label: 'Attended',
          tint: p.present,
          onTap: () => _add(ref, attended: true),
        ),
        const SizedBox(width: 6),
        _CountButton(
          icon: Icons.close_rounded,
          label: 'Missed',
          tint: p.absent,
          onTap: () => _add(ref, attended: false),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

class _CountButton extends StatelessWidget {
  const _CountButton({
    required this.icon,
    required this.label,
    required this.tint,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color tint;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          // 44 high keeps the target reachable where the icon alone would not.
          constraints: const BoxConstraints(minWidth: 52, minHeight: 44),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Icon(icon, size: 17, color: tint),
        ),
      ),
    );
  }
}

/// One entry in the overflow menu. A plain row rather than a [ListTile], which
/// wants more height than a [PopupMenuItem] gives it.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color tint = color ?? context.palette.textPrimary;
    return Row(
      children: <Widget>[
        Icon(icon, size: 19, color: tint),
        const SizedBox(width: AppSpacing.md),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: tint,
          ),
        ),
      ],
    );
  }
}

class _SubjectRow extends ConsumerWidget {
  const _SubjectRow({required this.subject});

  final Subject subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    final TimetableData? data = ref.watch(timetableProvider).value;
    final int? id = subject.id;
    final SubjectStats? stats =
        id == null ? null : ref.watch(subjectStatsProvider(id));

    final ClassCategory? category = data?.categoryFor(subject);
    final int classCount = _classCount(data, id);

    // Code first: a theory course and its lab share a name up to one word, so
    // the line has to lead with what differs. Totals live in the header, so
    // the count only appears when it is zero.
    final String detail = <String>[
      if (subject.code != null && subject.code!.isNotEmpty)
        subject.code!.toUpperCase(),
      if (category != null) category.name.toUpperCase(),
      if (subject.teacher != null && subject.teacher!.isNotEmpty)
        subject.teacher!,
      if (classCount == 0) 'no classes',
    ].join(' · ');

    final Color percentColor = healthColor(
      stats?.health ?? AttendanceHealth.empty,
      p,
    );

    // A subject with no class on the timetable has nothing to mark from the
    // day screen, so counting is the only way it can be kept up to date.
    final bool countsByHand = classCount == 0 &&
        (subject.priorHeld > 0 || subject.expectedTotal != null);

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(13, 12, 4, 12),
      onTap: () => showSubjectEditor(context, ref, subject: subject),
      onLongPress: () => showSubjectColorPicker(context, ref, subject),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              SubjectAvatar(
                initials: subject.initials,
                color: subject.color,
                size: 36,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      subject.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: p.textPrimary,
                      ),
                    ),
                    if (detail.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(color: p.textTertiary, size: 9.5),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                stats != null && stats.hasData
                    ? '${stats.percent.toStringAsFixed(0)}%'
                    : '—',
                style: TextStyle(
                  fontSize: 14,
                  height: 1,
                  fontWeight: stats?.hasData ?? false
                      ? FontWeight.w800
                      : FontWeight.w700,
                  letterSpacing: -0.3,
                  color: stats != null && stats.hasData
                      ? percentColor
                      : p.textFaint,
                ),
              ),
              PopupMenuButton<_SubjectAction>(
                icon: Icon(
                  Icons.more_vert_rounded,
                  size: 18,
                  color: p.textFaint,
                ),
                color: p.surface,
                onSelected: (_SubjectAction action) async {
                  switch (action) {
                    case _SubjectAction.edit:
                      await showSubjectEditor(context, ref, subject: subject);
                    case _SubjectAction.colour:
                      await showSubjectColorPicker(context, ref, subject);
                    case _SubjectAction.delete:
                      await _confirmDelete(context, ref, data);
                  }
                },
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<_SubjectAction>>[
                  const PopupMenuItem<_SubjectAction>(
                    value: _SubjectAction.edit,
                    child: _MenuRow(icon: Icons.edit_outlined, label: 'Edit'),
                  ),
                  const PopupMenuItem<_SubjectAction>(
                    value: _SubjectAction.colour,
                    child: _MenuRow(
                      icon: Icons.palette_outlined,
                      label: 'Change colour',
                    ),
                  ),
                  PopupMenuItem<_SubjectAction>(
                    value: _SubjectAction.delete,
                    child: _MenuRow(
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      color: p.absent,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (countsByHand) ...<Widget>[
            const SizedBox(height: 10),
            _BalanceCounter(subject: subject),
          ],
        ],
      ),
    );
  }

  /// Weekly rules plus one-off classes booked against this subject.
  int _classCount(TimetableData? data, int? id) {
    if (data == null || id == null) return 0;
    int count = 0;
    for (final ClassSlot slot in data.slots) {
      if (slot.subjectId == id) count++;
    }
    for (final ExtraClass extra in data.extras) {
      if (extra.subjectId == id) count++;
    }
    return count;
  }

  /// Deleting cascades to classes and history, so the dialog says exactly what
  /// is about to go rather than a vague warning.
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    TimetableData? data,
  ) async {
    final int? id = subject.id;
    if (id == null) return;

    // Grabbed up front: deleting unmounts this row, so looking the messenger up
    // afterwards would find nothing and the confirmation would never show.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    int slots = 0;
    int extras = 0;
    int marks = 0;
    if (data != null) {
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
      if (extras > 0)
        extras == 1 ? '1 one-off class' : '$extras one-off classes',
      if (marks > 0)
        marks == 1 ? '1 attendance mark' : '$marks attendance marks',
      // A carried balance is not a record, so counting only marks would offer
      // to delete a subject's whole history under "nothing else is lost".
      if (subject.priorHeld > 0)
        '${subject.priorAttended} of ${subject.priorHeld} carried in',
    ];

    final String message = losses.isEmpty
        ? 'Nothing is recorded against it yet, so nothing else is lost.'
        : '${subject.name} has ${_joinNaturally(losses)}. Deleting the subject '
            'removes all of it.';

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
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
      ),
    );

    if (confirmed != true) return;
    final TimetableActions actions = ref.read(actionsProvider);
    await actions.deleteSubject(id);
    showUndoSnack(messenger, actions, 'Deleted ${subject.name}');
  }

  /// "a, b and c" — reads like a sentence rather than a list of counts.
  String _joinNaturally(List<String> parts) {
    if (parts.length == 1) return parts.first;
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }
}
