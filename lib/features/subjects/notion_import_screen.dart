import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/class_category.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/notion_export.dart';
import '../../domain/notion_import.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';

/// What a Notion class log would do, subject by subject, before it does it.
///
/// The same shape as the other two imports: nothing is written until a human
/// has read it. What it adds is the grouping choice, which the export cannot
/// answer for itself — and which changes both the subjects created and what a
/// lab is worth, so the totals are re-read as it flips.
class NotionImportScreen extends ConsumerStatefulWidget {
  const NotionImportScreen({super.key, required this.export});

  final NotionExport export;

  @override
  ConsumerState<NotionImportScreen> createState() => _NotionImportScreenState();
}

class _NotionImportScreenState extends ConsumerState<NotionImportScreen> {
  /// Counting a longer class twice is the same choice as keeping the lab
  /// inside its course, so the categories answer it rather than the user.
  NotionGrouping? _chosen;

  NotionGrouping _groupingFrom(List<ClassCategory> categories) =>
      _chosen ??
      (categories.any((ClassCategory c) => c.weight > 1)
          ? NotionGrouping.grouped
          : NotionGrouping.separate);

  final Set<String> _excluded = <String>{};
  final Set<String> _seeded = <String>{};
  bool _saving = false;

  /// Subjects that would write over existing marks start out unticked.
  ///
  /// Seeded per subject rather than once for the screen, because flipping the
  /// grouping produces subjects that did not exist a moment ago: "Data
  /// Structures Lab" is only a name in the split view, and it can conflict
  /// there while the course it came from did not. Seeding once left those
  /// ticked and would have written over marks.
  ///
  /// Keyed by name, so a subject that survives the flip keeps whatever the
  /// user decided about it.
  void _seed(NotionPlan plan, {required bool ready}) {
    // Against a database that has not loaded every subject looks new, and
    // seeding from that would tick the conflicts.
    if (!ready) return;
    for (final NotionPlanSubject s in plan.subjects) {
      if (!_seeded.add(s.name)) continue;
      if (s.match == NotionMatch.overlap) _excluded.add(s.name);
    }
  }

  Future<void> _apply(NotionPlan plan) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _saving = true);

    final TimetableActions actions = ref.read(actionsProvider);
    final int count = await actions.importNotionLog(<NotionPlanSubject>[
      for (final NotionPlanSubject s in plan.subjects)
        if (!_excluded.contains(s.name)) s,
    ]);
    if (!mounted) return;
    navigator.pop();
    showUndoSnack(
      messenger,
      actions,
      'Brought in ${Words.plural(count, 'class', 'classes')}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final TimetableData? data = ref.watch(timetableProvider).value;
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();

    final NotionGrouping grouping =
        _groupingFrom(data?.categories ?? const <ClassCategory>[]);
    final NotionPlan plan = NotionPlan.from(
      export: widget.export,
      grouping: grouping,
      subjects: data?.subjects ?? const <Subject>[],
      slots: data?.slots ?? const <ClassSlot>[],
      records: data?.records ?? const <AttendanceRecord>[],
    );
    _seed(plan, ready: data != null);

    final List<NotionPlanSubject> chosen = <NotionPlanSubject>[
      for (final NotionPlanSubject s in plan.subjects)
        if (!_excluded.contains(s.name)) s,
    ];
    final int classes = chosen.fold<int>(
      0,
      (int sum, NotionPlanSubject s) => sum + s.classes,
    );

    return PushScaffold(
      title: 'Classes from Notion',
      subtitle: '${Words.plural(plan.subjects.length, 'subject')} · '
          '${Words.plural(classes, 'class', 'classes')} to bring in',
      floatingActionButton: classes == 0 || _saving
          ? null
          : GradientFab(
              label: 'Bring in $classes',
              onPressed: () => _apply(plan),
            ),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          sliver: SliverList.list(
            children: <Widget>[
              if (widget.export.problems.isNotEmpty)
                _Problems(problems: widget.export.problems),
              _OutsideTermWarning(export: widget.export, settings: settings),
              const SectionHeader('How the courses split'),
              _GroupingChoice(
                value: grouping,
                onChanged: (NotionGrouping g) => setState(() => _chosen = g),
              ),
              const SizedBox(height: AppSpacing.xl),
              SectionHeader(
                'What was read',
                trailing: Text(
                  _span(widget.export),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: p.textTertiary,
                  ),
                ),
              ),
              for (final NotionPlanSubject s in plan.subjects) ...<Widget>[
                _SubjectCard(
                  planned: s,
                  excluded: _excluded.contains(s.name),
                  onToggle: () => setState(() {
                    if (!_excluded.remove(s.name)) _excluded.add(s.name);
                  }),
                ),
                const SizedBox(height: 10),
              ],
              Text(
                'Every class is written as its own mark, so the attendance log '
                'reads day by day rather than as one carried total.',
                style: TextStyle(fontSize: 12, height: 1.45, color: p.textFaint),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _span(NotionExport export) {
    final DateTime? from = export.firstDate;
    final DateTime? to = export.lastDate;
    if (from == null || to == null) return '';
    return '${Dates.formatDayMonth(from)} – ${Dates.formatDayMonth(to)}';
  }
}

/// The one thing the file cannot say for itself.
class _GroupingChoice extends StatelessWidget {
  const _GroupingChoice({required this.value, required this.onChanged});

  final NotionGrouping value;
  final ValueChanged<NotionGrouping> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final NotionGrouping option in NotionGrouping.values) ...<Widget>[
          SurfaceCard(
            onTap: () => onChanged(option),
            child: Row(
              children: <Widget>[
                Icon(
                  option == value
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: option == value ? p.accent : p.textFaint,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        option == NotionGrouping.grouped
                            ? 'One subject per course'
                            : 'Lecture and lab kept apart',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        option == NotionGrouping.grouped
                            ? 'The lab sits inside its course and counts for '
                                'as much as the file says — a two-period lab '
                                'twice.'
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

/// Rows the reader could not use. Named rather than quietly missing.
class _Problems extends StatelessWidget {
  const _Problems({required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${Words.plural(problems.length, 'row')} could not be read',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: p.absent,
              ),
            ),
            const SizedBox(height: 6),
            for (final String problem in problems.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  problem,
                  style: monoStyle(color: p.textTertiary, size: 10.5),
                ),
              ),
            if (problems.length > 5)
              Text(
                'and ${problems.length - 5} more',
                style: monoStyle(color: p.textFaint, size: 10.5),
              ),
          ],
        ),
      ),
    );
  }
}

/// The marks would import and then not count, which is worth knowing before
/// rather than after.
class _OutsideTermWarning extends StatelessWidget {
  const _OutsideTermWarning({required this.export, required this.settings});

  final NotionExport export;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final DateTime? from = export.firstDate;
    final DateTime? to = export.lastDate;
    if (from == null || to == null) return const SizedBox.shrink();
    if (settings.countsInTerm(from) && settings.countsInTerm(to)) {
      return const SizedBox.shrink();
    }

    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Some of these fall outside your term',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: p.warning,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'They will be brought in and shown in the attendance log, but '
              'the percentages only count classes inside the semester dates. '
              'Widen the term in Settings if these should count.',
              style: TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubjectCard extends StatelessWidget {
  const _SubjectCard({
    required this.planned,
    required this.excluded,
    required this.onToggle,
  });

  final NotionPlanSubject planned;
  final bool excluded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    final List<String> notes = <String>[
      if (planned.match == NotionMatch.overlap)
        'You have marked ${Words.plural(planned.marksInRange, 'class', 'classes')} '
            'here between these dates. The file covers those days too, so '
            'bringing this in replaces them rather than adding to them.',
      if (planned.unscheduled > 0)
        '${Words.plural(planned.unscheduled, 'class', 'classes')} had no '
            'matching class on your timetable that day. They still count, and '
            'show in the log as left over from a rule that is not there.',
      if (planned.suspect > 0)
        '${Words.plural(planned.suspect, 'row')} disagree with their own '
            'credit column — attended but credited nothing, or the other way '
            'round.',
    ];

    return SurfaceCard(
      onTap: onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Checkbox.adaptive(
                value: !excluded,
                onChanged: (_) => onToggle(),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  planned.name,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: excluded ? p.textFaint : p.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Pill(
                label: switch (planned.match) {
                  NotionMatch.create => 'NEW',
                  NotionMatch.update => 'UPDATE',
                  NotionMatch.overlap => 'CONFLICT',
                },
                color: switch (planned.match) {
                  NotionMatch.create => p.present,
                  NotionMatch.update => p.textTertiary,
                  NotionMatch.overlap => p.warning,
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            <String>[
              if (planned.code != null) planned.code!,
              '${planned.attended} of ${planned.held}'
                  '${planned.hasWeighted ? ' periods' : ''}',
              '${planned.classes} marked',
              for (final MapEntry<String, int> label in planned.labels.entries)
                '${label.value} ${label.key.toLowerCase()}',
            ].join(' · '),
            style: monoStyle(color: p.textTertiary, size: 10.5),
          ),
          for (final String note in notes) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              note,
              style: TextStyle(fontSize: 12, height: 1.4, color: p.warning),
            ),
          ],
        ],
      ),
    );
  }
}
