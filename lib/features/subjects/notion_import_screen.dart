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
import '../../domain/class_weight.dart';
import '../../domain/notion_export.dart';
import '../../domain/notion_import.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/course_split_choice.dart';
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

  bool _countUntyped = true;

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

    final ActionCore core = ref.read(actionCoreProvider);
    final ImportActions imports = ref.read(importActionsProvider);
    final int count = await imports.importNotionLog(
      <NotionPlanSubject>[
        for (final NotionPlanSubject s in plan.subjects)
          if (!_excluded.contains(s.name)) s,
      ],
      cancelledCounts: plan.countsCancelled,
      typeWeights: plan.typeWeights,
    );
    if (!mounted) return;
    navigator.pop();
    showUndoSnack(
      messenger,
      core,
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
      countsCancelledNow: settings.cancelledCountsAsAttended,
      countUntyped: _countUntyped,
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
              _CancelledRule(plan: plan, settings: settings),
              _TypeWorth(
                plan: plan,
                types: data?.categories ?? const <ClassCategory>[],
              ),
              if (plan.untyped > 0)
                _UntypedChoice(
                  rows: plan.untyped,
                  counted: _countUntyped,
                  onChanged: (bool on) => setState(() => _countUntyped = on),
                ),
              const SectionHeader('How the courses split'),
              CourseSplitChoice(
                grouped: grouping == NotionGrouping.grouped,
                source: 'file',
                onChanged: (bool g) => setState(() => _chosen =
                    g ? NotionGrouping.grouped : NotionGrouping.separate),
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
                style:
                    TextStyle(fontSize: 12, height: 1.45, color: p.textFaint),
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
                  // A sentence, not a figure — mono is for the numbers.
                  style: TextStyle(fontSize: 10.5, color: p.textTertiary),
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
              'the percentages only count classes inside the term dates. '
              'Widen the term in Settings if these should count.',
              style: TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one setting an import changes, said before it does.
class _CancelledRule extends StatelessWidget {
  const _CancelledRule({required this.plan, required this.settings});

  final NotionPlan plan;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final bool? counts = plan.countsCancelled;
    if (counts == null || counts == settings.cancelledCountsAsAttended) {
      return const SizedBox.shrink();
    }

    final AppPalette p = context.palette;
    final int otherwise = plan.creditedOtherwise;
    final String why = counts
        ? 'Your table credits its cancelled classes, so this turns on'
        : 'Your table does not credit its cancelled classes, so this turns off';
    final String rest = otherwise == 0
        ? ''
        : ' ${Words.plural(otherwise, 'cancelled class', 'cancelled classes')} '
            '${otherwise == 1 ? 'is' : 'are'} credited the other way and will '
            'follow the setting too.';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              counts
                  ? 'Cancelled classes will count as attended'
                  : 'Cancelled classes will stop counting',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: p.warning,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '$why Cancelled classes count as attended in Settings.$rest',
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// The class types whose worth the import sets, said before it does. A type
/// already worth what the table counts goes unmentioned.
class _TypeWorth extends StatelessWidget {
  const _TypeWorth({required this.plan, required this.types});

  final NotionPlan plan;
  final List<ClassCategory> types;

  @override
  Widget build(BuildContext context) {
    final List<String> lines = <String>[
      for (final MapEntry<String, int> type in plan.typeWeights.entries)
        if (type.value !=
            (types
                    .where((ClassCategory c) =>
                        c.name.toLowerCase() == type.key.toLowerCase())
                    .firstOrNull
                    ?.weight ??
                1))
          '${type.key}: ${classWeightLabel(type.value)}',
    ];
    if (lines.isEmpty) return const SizedBox.shrink();

    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Class types will count as your table counts them',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: p.warning,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '${lines.join(' · ')}. Classes you add later count the same. '
              'Marks already in the app keep what they were worth.',
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rows the table cannot count for want of a class type. Asked, not assumed:
/// whether they were real classes is something only the student knows.
class _UntypedChoice extends StatelessWidget {
  const _UntypedChoice({
    required this.rows,
    required this.counted,
    required this.onChanged,
  });

  final int rows;
  final bool counted;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${Words.plural(rows, 'class', 'classes')} with no type',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: p.warning,
                    ),
                  ),
                ),
                Switch(value: counted, onChanged: onChanged),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              counted
                  ? 'Your table counts none of these, because their type is '
                      'empty. They will count here, and syncing fills in the '
                      "course's type so your table counts them too."
                  : 'Your table counts none of these, because their type is '
                      'empty. They will come in without counting, as they are '
                      'there.',
              style: const TextStyle(fontSize: 12.5, height: 1.4),
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
