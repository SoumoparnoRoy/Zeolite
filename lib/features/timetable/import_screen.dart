import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../domain/day_grid.dart';
import '../../domain/timetable_import.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// Types a whole timetable in one paste instead of twenty trips through the
/// class sheet.
///
/// The paste is re-read on every keystroke and shown back as the classes it
/// would create, because the printed timetable it is copied from can itself be
/// wrong — a period that runs from 15:50 printed as 16:00, say — and this is
/// the only place anyone can catch that before it is written.
class ImportTimetableScreen extends ConsumerStatefulWidget {
  const ImportTimetableScreen({super.key});

  @override
  ConsumerState<ImportTimetableScreen> createState() =>
      _ImportTimetableScreenState();
}

class _ImportTimetableScreenState
    extends ConsumerState<ImportTimetableScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import(TimetableImportResult result) async {
    setState(() => _saving = true);
    await ref.read(actionsProvider).importTimetable(result);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final DayGrid grid = ref.watch(dayGridProvider);
    final bool use24Hour =
        ref.watch(settingsProvider).value?.use24HourTime ?? false;
    final TimetableImportResult result =
        TimetableImport.parse(_controller.text, grid: grid);
    final bool ready =
        !result.isEmpty && !result.hasProblems && !_saving;

    return PushScaffold(
      title: 'Import timetable',
      subtitle: result.isEmpty
          ? null
          : '${result.classes.length} '
              '${result.classes.length == 1 ? 'class' : 'classes'} · '
              '${result.subjectNames.length} '
              '${result.subjectNames.length == 1 ? 'subject' : 'subjects'}',
      floatingActionButton: ready
          ? GradientFab(
              label: 'Add ${result.classes.length} to my timetable',
              onPressed: () => _import(result),
            )
          : null,
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          sliver: SliverList.list(children: <Widget>[
            _FormatHelp(grid: grid),
            const SizedBox(height: AppSpacing.md),
            SurfaceCard(
              child: TextField(
                controller: _controller,
                maxLines: null,
                minLines: 8,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.6,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'CSE2039L, Mo, 1-2, B120, DK',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (result.hasProblems) ...<Widget>[
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Fix these first'),
              for (final ImportLine line in result.problems)
                _ProblemRow(line: line),
            ],
            if (result.classes.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('What will be added'),
              for (final int weekday in _weekdaysIn(result))
                _DayGroup(
                  weekday: weekday,
                  result: result,
                  use24Hour: use24Hour,
                ),
            ],
          ]),
        ),
      ],
    );
  }

  static List<int> _weekdaysIn(TimetableImportResult result) {
    final Set<int> days =
        result.classes.map((ImportedClass c) => c.weekday).toSet();
    return days.toList()..sort();
  }
}

class _FormatHelp extends StatelessWidget {
  const _FormatHelp({required this.grid});

  final DayGrid grid;

  @override
  Widget build(BuildContext context) {
    return GroupNote(
      'One class per line: subject, day, blocks, room, teacher. The room and '
      'teacher can be left off. A lab across two periods is "1-2". '
      '${grid.isConfigured ? 'Block numbers count against the teaching day you '
          'set up, and a time like "14:20-15:20" works too.' : 'The teaching '
          'day has no blocks yet, so write times like "14:20-15:20".'} '
      'Subjects are matched by name, so the same one typed twice is one '
      'subject. Nothing is written until you say so, and importing adds to '
      'what you already have.',
    );
  }
}

class _ProblemRow extends StatelessWidget {
  const _ProblemRow({required this.line});

  final ImportLine line;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 58,
            child: Text(
              'Line ${line.number}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: context.palette.absent,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  line.error!,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.palette.absent,
                  ),
                ),
                Text(
                  line.text,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: context.palette.textTertiary,
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

class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.weekday,
    required this.result,
    required this.use24Hour,
  });

  final int weekday;
  final TimetableImportResult result;
  final bool use24Hour;

  @override
  Widget build(BuildContext context) {
    final List<ImportedClass> classes = result.classes
        .where((ImportedClass c) => c.weekday == weekday)
        .toList()
      ..sort((ImportedClass a, ImportedClass b) =>
          a.startMinutes.compareTo(b.startMinutes));

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DayRule(label: kWeekdayNamesLong[weekday - 1]),
          for (final ImportedClass c in classes)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 116,
                    child: Text(
                      '${Clock.format(c.startMinutes, use24Hour: use24Hour)}'
                      ' – '
                      '${Clock.format(c.endMinutes, use24Hour: use24Hour)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      c.subjectName,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (c.room != null)
                    Text(
                      c.room!,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.textTertiary,
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
