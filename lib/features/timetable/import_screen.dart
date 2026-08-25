import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../domain/attendance_totals_ocr.dart';
import '../../domain/day_grid.dart';
import '../../domain/timetable_import.dart';
import '../../domain/timetable_ocr.dart';
import '../../services/text_recognition.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/totals_import_screen.dart';

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
  bool _reading = false;

  /// Off unless asked for: most timetables count every class once, and turning
  /// this on by default would silently double every lab already being pasted.
  bool _weighByBlocks = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import(TimetableImportResult result) async {
    setState(() => _saving = true);
    // The screen pops on success, so the offer is raised on the messenger
    // rather than through this route's context.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final TimetableActions actions = ref.read(actionsProvider);
    final int count = result.classes.length;
    await actions.importTimetable(result, weighByBlocks: _weighByBlocks);
    if (mounted) Navigator.of(context).pop();
    showUndoSnack(
      messenger,
      actions,
      'Added ${Words.plural(count, 'class', 'classes')} to your timetable',
    );
  }

  /// What lands is a first draft: a cell holding parallel electives becomes one
  /// line per elective, because only the student knows which is theirs.
  Future<void> _readImage() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _reading = true);
    try {
      final PlatformFile? picked = await FilePicker.pickFile();
      if (picked == null) return;
      final Uint8List bytes = await picked.readAsBytes();
      final List<OcrLine> lines = await TextRecognition.readImage(bytes);

      // Spotted before the timetable parse, which would only fail on it.
      if (AttendanceTotalsOcr.looksLikeTotals(lines)) {
        // A second look at the number columns alone, which is the only way the
        // single digits come back off a page this dense.
        final OcrBox? columns = AttendanceTotalsOcr.numberColumns(lines);
        final List<OcrLine>? cells = columns == null
            ? null
            : await TextRecognition.readRegion(bytes, columns);
        final AttendanceTotals? totals = AttendanceTotalsOcr.read(
          lines,
          cells: cells == null || cells.isEmpty ? null : cells,
        );
        if (!mounted) return;
        if (totals == null || totals.rows.isEmpty) {
          messenger.showSnackBar(const SnackBar(
            content: Text('That looks like an attendance page, but no course '
                'rows could be read off it.'),
          ));
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TotalsImportScreen(totals: totals),
          ),
        );
        return;
      }

      final TimetableGrid? grid = TimetableGridReader.read(lines);
      final List<String> read =
          grid == null ? <String>[] : TimetableOcr.toLines(lines, grid);
      if (read.isEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text(grid == null
              ? 'Could not find a timetable in that image. The weekdays and '
                  'the period times both have to be readable.'
              : 'Found the grid, but no classes in it.'),
        ));
        return;
      }
      if (!mounted) return;
      setState(() => _controller.text = read.join('\n'));
      messenger.showSnackBar(SnackBar(
        content: Text('Read ${Words.plural(read.length, 'line')} — check them '
            'against the sheet before importing.'),
      ));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not read that image: $error')),
      );
    } finally {
      if (mounted) setState(() => _reading = false);
    }
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
            OutlinedButton.icon(
              onPressed: _reading ? null : _readImage,
              icon: const Icon(Icons.image_outlined, size: 18),
              label: Text(_reading ? 'Reading…' : 'Read from an image'),
            ),
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
                  hintText: 'ECE2104L, Mo, 1-2, B415, SM',
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
            if (result.classes.isNotEmpty &&
                result.classes.any((ImportedClass c) => c.blocks > 1)) ...<Widget>[
              const SizedBox(height: AppSpacing.xl),
              _BlockWeightChoice(
                value: _weighByBlocks,
                onChanged: (bool v) => setState(() => _weighByBlocks = v),
              ),
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

/// Offered only when the paste actually holds a class longer than one block,
/// so a timetable of single periods never has to read the question.
class _BlockWeightChoice extends StatelessWidget {
  const _BlockWeightChoice({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SurfaceCard(
      onTap: () => onChanged(!value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Checkbox.adaptive(
            value: value,
            onChanged: (bool? v) => onChanged(v ?? false),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Count a two-block class as two',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'For an institution that counts a two-hour lab twice towards '
                  'attendance. You can change this per class afterwards.',
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
