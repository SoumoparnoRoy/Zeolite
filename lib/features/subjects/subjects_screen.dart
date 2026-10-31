import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/words.dart';
import '../../data/models/class_category.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/subject.dart';
import '../../domain/attendance_stats.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';
import '../stats/stats_view.dart';
import 'class_editor_sheets.dart';
import 'subject_delete_dialog.dart';

/// Every subject in one place: add, edit, recolour and delete.
///
/// Pushed from Settings. The rest of the app edits subjects incidentally — from
/// a class editor or a stats card — so this is the one screen that treats them
/// as the list they are.
class SubjectsScreen extends ConsumerWidget {
  const SubjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<TimetableData> loaded = ref.watch(timetableProvider);
    final TimetableData? timetable = loaded.value;
    // Already ordered by name from the repository.
    final List<Subject> subjects = timetable?.subjects ?? <Subject>[];
    final int weekly = timetable?.slots.length ?? 0;

    return PushScaffold(
      title: 'Subjects',
      subtitle: subjects.isEmpty
          ? null
          : '${Words.plural(subjects.length, 'subject')}'
              ' · $weekly weekly ${Words.noun(weekly, 'class', 'classes')}',
      floatingActionButton: subjects.isEmpty
          ? null
          : GradientFab(
              label: 'Add subject',
              onPressed: () => showSubjectEditor(context),
            ),
      slivers: <Widget>[
        if (!loaded.hasValue)
          SliverFillRemaining(
            hasScrollBody: false,
            child: loaded.hasError
                ? Padding(
                    padding: const EdgeInsets.only(top: 40, bottom: 60),
                    child: LoadFailed(
                      onRetry: () => ref.invalidate(timetableProvider),
                    ),
                  )
                : const SizedBox.shrink(),
          )
        else if (subjects.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 40, bottom: 60),
              child: EmptyState(
                icon: Icons.school_outlined,
                title: 'No subjects yet',
                message: 'Add the subjects you are taking. Classes hang off a '
                    'subject, and your attendance is tracked per subject.',
                action: FilledButton.icon(
                  onPressed: () => showSubjectEditor(context),
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
              itemBuilder: (BuildContext context, int index) => _SubjectRow(
                key: ValueKey<int?>(subjects[index].id),
                subject: subjects[index],
              ),
            ),
          ),
      ],
    );
  }
}

enum _SubjectAction { edit, colour, delete }

/// A subject with no classes is kept on the Counts page, so its row sends it
/// there rather than offering a second way to count.
class _CountsLink extends ConsumerWidget {
  const _CountsLink({required this.subject});

  final Subject subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '${subject.priorAttended} of ${subject.priorHeld} attended',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                monoStyle(color: p.textTertiary, size: AppType.captionMedium),
          ),
        ),
        TextButton.icon(
          onPressed: () {
            ref.read(statsViewProvider.notifier).show(StatsView.counts);
            ref
                .read(selectedTabProvider.notifier)
                .select(shellTabs.indexOf('stats'));
            Navigator.of(context).popUntil(ModalRoute.withName('/'));
          },
          icon: const Icon(Icons.exposure_plus_1_rounded, size: 18),
          label: const Text('Count on the Stats page'),
        ),
      ],
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
            fontSize: AppType.titleMedium,
            fontWeight: FontWeight.w500,
            color: tint,
          ),
        ),
      ],
    );
  }
}

class _SubjectRow extends ConsumerStatefulWidget {
  const _SubjectRow({super.key, required this.subject});

  final Subject subject;

  @override
  ConsumerState<_SubjectRow> createState() => _SubjectRowState();
}

class _SubjectRowState extends ConsumerState<_SubjectRow> {
  // The dialog lets taps through while it fades, and the row stays drawn
  // until the delete lands, so the second tap of a double tap on *Delete*
  // would otherwise open the editor for a subject that is going away.
  bool _deleting = false;
  bool _menuOpen = false;

  Subject get subject => widget.subject;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final TimetableData? timetable = ref.watch(timetableProvider).value;
    final int? id = subject.id;
    final SubjectStats? stats =
        id == null ? null : ref.watch(subjectStatsProvider(id));

    final ClassCategory? category = timetable?.categoryFor(subject);
    final int classCount = _classCount(timetable, id);

    // Code first: a theory course and its lab share a name up to one word, so
    // the line has to lead with what differs. Totals live in the header, so
    // the count only appears when it is zero.
    final String detail = <String>[
      if (subject.code != null && subject.code!.isNotEmpty)
        subject.code!.toUpperCase(),
      if (category != null) category.name,
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
      onTap: () {
        if (_deleting) return;
        showSubjectEditor(context, subject: subject);
      },
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
                        fontSize: AppType.bodyMedium,
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
                        style: monoStyle(
                            color: p.textTertiary, size: AppType.captionSmall),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                stats != null && stats.hasData
                    ? Words.attendance(stats.percent)
                    : '—',
                style: TextStyle(
                  fontSize: AppType.titleMedium,
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
              // A Builder so the menu opens over the button's own box.
              Builder(
                builder: (BuildContext button) => IconButton(
                  icon: Semantics(
                    expanded: _menuOpen,
                    child: Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: p.textFaint,
                    ),
                  ),
                  padding: const EdgeInsets.all(8),
                  tooltip: MaterialLocalizations.of(button).showMenuTooltip,
                  onPressed: () => _openMenu(button, timetable),
                ),
              ),
            ],
          ),
          if (countsByHand) ...<Widget>[
            const SizedBox(height: 10),
            _CountsLink(subject: subject),
          ],
        ],
      ),
    );
  }

  Future<void> _openMenu(BuildContext button, TimetableData? data) async {
    final AppPalette p = context.palette;
    setState(() => _menuOpen = true);
    final _SubjectAction? action = await showAppMenu<_SubjectAction>(
      context: button,
      color: p.surface,
      items: <PopupMenuEntry<_SubjectAction>>[
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
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    if (action == null) return;
    switch (action) {
      case _SubjectAction.edit:
        await showSubjectEditor(context, subject: subject);
      case _SubjectAction.colour:
        await showSubjectColorPicker(context, ref, subject);
      case _SubjectAction.delete:
        await _confirmDelete(data);
    }
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
  Future<void> _confirmDelete(TimetableData? data) async {
    final int? id = subject.id;
    if (id == null) return;

    // Grabbed up front: deleting unmounts this row, so looking the messenger up
    // afterwards would find nothing and the confirmation would never show.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await confirmSubjectDelete(context, subject, data);

    if (!confirmed) return;
    _deleting = true;
    final ActionCore core = ref.read(actionCoreProvider);
    final SubjectActions subjects = ref.read(subjectActionsProvider);
    try {
      await subjects.deleteSubject(id);
    } catch (_) {
      // The subject is still there, so its row has to open again.
      _deleting = false;
      rethrow;
    }
    showUndoSnack(messenger, core, '${subject.name} deleted');
  }
}
