import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../domain/attendance_totals_ocr.dart';
import '../../domain/day_grid.dart';
import '../../domain/grid_lines.dart';
import '../../domain/timetable_choices.dart';
import '../../domain/timetable_import.dart';
import '../../domain/timetable_ocr.dart';
import '../../domain/vision_merge.dart';
import '../../domain/vision_read.dart';
import '../../services/image_edges.dart';
import '../../services/text_recognition.dart';
import '../../services/timetable/vision_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/course_split_choice.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/totals_import_screen.dart';
import 'import_choices_screen.dart';

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

  /// A lab kept inside its course is what the choice exists for, so a sheet
  /// that names both starts that way.
  bool _byCourse = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The widest the copy that leaves the device is drawn. Past this is tokens
  /// spent on detail the model tiles away.
  static const int _sentWidth = 1600;

  /// Asks a model what it sees, and folds anything new into the local read.
  ///
  /// Returns [entries] untouched on every refusal and every failure.
  Future<List<OcrEntry>> _secondOpinion({
    required TimetableGrid grid,
    required List<OcrEntry> entries,
    required List<OcrLine> lines,
    required Uint8List bytes,
    required ScaffoldMessengerState messenger,
  }) async {
    if (!await _agreesToSend()) return entries;

    // Blocking and undismissable on purpose: the call runs 45 to 115 seconds
    // on a dense sheet, and the button behind still reads "Reading...", which
    // is what the local read says. Without this the wait looks like a hang.
    if (!mounted) return entries;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CheckingDialog(),
    ));

    final VisionClient client = VisionClient();
    final VisionRead read;
    try {
      read = await client.read(
        image: await TextRecognition.narrowedTo(bytes, _sentWidth),
        text: <String>[for (final OcrLine l in lines) l.text].join('\n'),
      );
    } finally {
      client.close();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    if (!read.ok) {
      messenger.showSnackBar(SnackBar(content: Text(_saidAbout(read.failure!))));
      return entries;
    }

    final List<OcrEntry> found = VisionMerge.corroboratedBy(
      grid,
      lines,
      VisionMerge.placedOn(grid, read.classes),
    );
    final List<OcrEntry> merged = VisionMerge.filling(entries, found);
    final int added = merged.length - entries.length;
    messenger.showSnackBar(SnackBar(
      content: Text(added == 0
          ? 'The AI check found nothing this device missed.'
          : 'The AI check added ${Words.plural(added, 'class')}. '
              'Check them against the sheet.'),
    ));
    return merged;
  }

  /// Per read, never remembered: the policy can only say the image leaves the
  /// device when the student asked it to if it is asked every time.
  Future<bool> _agreesToSend() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Check this sheet with AI?'),
        content: const Text(
          'Some of the period times on this sheet could not be read with '
          'confidence. Zeolite can send a copy of the image to its server, '
          'which asks an AI to read it and then deletes it.\n\n'
          'Nothing else about you is sent, and the times stay the ones '
          'printed on the sheet.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No thanks'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Check with AI'),
          ),
        ],
      ),
    );
    return yes ?? false;
  }

  /// Says nothing about the provider or the upstream fault — "try later" is
  /// the only part of it the student can act on.
  static String _saidAbout(VisionFailure failure) {
    switch (failure) {
      case VisionFailure.unavailable:
        return 'Checking a sheet with AI is not available in this version.';
      case VisionFailure.busy:
        return "Today's AI checks have been used up. Try again tomorrow.";
      case VisionFailure.offline:
        return 'Could not reach the server. The read on this device is '
            'unchanged.';
      case VisionFailure.failed:
      case VisionFailure.unreadable:
        return 'The AI check could not read that sheet either.';
    }
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

  /// Reads each doubted period header again on its own, magnified far past
  /// anything the whole page would fit into, and puts back any clock that
  /// comes out of it.
  ///
  /// Doubted rather than blank: `11:40- 12:30` losing its leading digit reads
  /// as a valid 1:40 that the schedule then has to overrule.
  static Future<TimetableGrid> _namedHeaders(
    TimetableGrid grid,
    TableLattice lattice,
    Uint8List bytes,
  ) async {
    TimetableGrid out = grid;
    for (final int p in TimetableOcr.doubtedPeriods(grid)) {
      final OcrBox? box = TimetableGridReader.headerBoxOf(grid, lattice, p);
      if (box == null) continue;
      final List<OcrLine> read = await TextRecognition.readRegion(bytes, box);
      for (final OcrLine line in read) {
        if (!TimetableGridReader.namesATime(line.text)) continue;
        out = out.withPeriodLabel(p, line.text.trim());
        break;
      }
    }
    return out;
  }

  /// Reads the cell behind each oddly-named class again on its own, and keeps
  /// the second reading only when it comes back in the shape the sheet uses.
  ///
  /// The same magnification the headers get, for the same reason: a lost block
  /// letter and a lost code are each one character on a page scaled to fit.
  static Future<List<OcrEntry>> _namedOddCells(
    TimetableGrid grid,
    List<OcrEntry> entries,
    Uint8List bytes,
  ) async {
    final List<OcrEntry> out = List<OcrEntry>.of(entries);
    for (final ({OcrEntry entry, bool room, String text}) odd
        in TimetableOcr.oddlyNamed(entries)) {
      final OcrBox? box = TimetableOcr.cellBoxOf(grid, odd.entry);
      if (box == null) continue;
      final int at = out.indexOf(odd.entry);
      if (at < 0) continue;
      final List<OcrLine> read = await TextRecognition.readRegion(bytes, box);
      final String? named = TimetableOcr.namedInShape(read, room: odd.room);
      if (named == null || named == odd.text) continue;
      out[at] = odd.room
          ? out[at].withName(room: named)
          : out[at].withName(subject: named);
    }
    return out;
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
      final ImageReads reads = await TextRecognition.readImage(bytes);
      final List<OcrLine> lines = reads.best;

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
            settings: const RouteSettings(name: 'totals_import'),
            builder: (_) => TotalsImportScreen(totals: totals),
          ),
        );
        return;
      }

      // The table's own ruling, read off the pixels rather than off the text.
      // Both reads get the same one, so they differ only in what they say.
      final TableLattice? lattice = await ImageEdges.rulesOf(bytes);

      // Every read, not just the best one: which of them reads this sheet
      // furthest is a property of the sheet, not something decidable upstream.
      ({TimetableGrid? grid, List<OcrEntry> entries, List<OcrLine> lines}) best =
          TimetableOcr.bestOf(reads.all, lattice: lattice);

      if (lattice != null && best.grid != null) {
        final TimetableGrid named = await _namedHeaders(
          best.grid!,
          lattice,
          bytes,
        );
        if (!identical(named, best.grid)) {
          best = (
            grid: named,
            entries: TimetableOcr.read(best.lines, named),
            lines: best.lines,
          );
        }
      }
      // After the headers, because a class whose clock moved is a different
      // cell to go back to.
      if (lattice != null && best.grid != null && best.entries.isNotEmpty) {
        best = (
          grid: best.grid,
          entries: await _namedOddCells(best.grid!, best.entries, bytes),
          lines: best.lines,
        );
      }

      if (best.entries.isEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text(best.grid == null
              ? 'Could not find a timetable in that image. The weekdays and '
                  'the period times both have to be readable.'
              : 'Found the grid, but no classes in it.'),
        ));
        return;
      }

      // A doubted read is the only one worth sending anywhere, and even then
      // only if the student says so.
      List<OcrEntry> entries = best.entries;
      final ReadConfidence confidence =
          TimetableOcr.confidenceOf(best.grid, entries);
      if (!confidence.isConfident && best.grid != null) {
        if (!mounted) return;
        entries = await _secondOpinion(
          grid: best.grid!,
          entries: entries,
          lines: lines,
          bytes: bytes,
          messenger: messenger,
        );
      }

      entries = TimetableOcr.withCodesMended(entries);
      final int boxes = entries.length;
      entries = TimetableOcr.joinedRuns(entries);
      // Two boxes were two classes before they were joined, so the joined one
      // keeps counting as two unless the student says otherwise.
      if (entries.length < boxes) setState(() => _weighByBlocks = true);

      // Only the axes that actually offer a choice: a sheet where every lab
      // is B1 has nothing to ask about.
      final Map<String, List<String>> axes = <String, List<String>>{
        for (final MapEntry<String, List<String>> axis
            in TimetableOcr.groupAxesIn(entries).entries)
          if (axis.value.length > 1) axis.key: axis.value,
      };
      final List<ElectiveBasket> baskets = TimetableOcr.basketsIn(entries);

      TimetableChoices choices = TimetableChoices(baskets: baskets);
      if (axes.isNotEmpty || baskets.isNotEmpty) {
        if (!mounted) return;
        final TimetableChoices? answered =
            await Navigator.of(context).push<TimetableChoices>(
          MaterialPageRoute<TimetableChoices>(
            settings: const RouteSettings(name: 'import_choices'),
            builder: (_) => ImportChoicesScreen(
              entries: entries,
              axes: axes,
              baskets: baskets,
              use24Hour:
                  ref.read(settingsProvider).value?.use24HourTime ?? false,
            ),
          ),
        );
        if (!mounted) return;
        if (answered != null) choices = answered;
      }

      // Behind a `#`, which the parser already skips, so answering wrong
      // costs a deleted character rather than another read of the image.
      final List<String> read = <String>[
        for (final OcrEntry e in entries)
          if (choices.keeps(e)) e.toLine() else '# ${e.toLine()}',
      ];
      final int kept = read.where((String l) => !l.startsWith('#')).length;

      if (!mounted) return;
      setState(() => _controller.text = read.join('\n'));
      messenger.showSnackBar(SnackBar(
        content: Text(choices.isEmpty
            ? 'Read ${Words.plural(kept, 'line')} — check them against the '
                'sheet before importing'
            : 'Read ${Words.plural(kept, 'line')} of ${entries.length}. The '
                'rest are commented out.'),
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
    final TimetableImportResult result = TimetableImport.parse(
      _controller.text,
      grid: grid,
      byCourse: _byCourse,
    );
    final bool splits = result.subjectNames.length !=
        TimetableImport.parse(_controller.text, grid: grid, byCourse: !_byCourse)
            .subjectNames
            .length;
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
                  hintText: 'Subject 1, Mo, 1-2, Room 1, Professor 1',
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
            if (result.lookalikes.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('These may be the same'),
              for (final List<String> group in result.lookalikes)
                _LookalikeRow(names: group),
            ],
            if (result.oddlyNamed.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Named unlike the rest'),
              for (final String name in result.oddlyNamed)
                _OddNameRow(name: name),
            ],
            if (splits) ...<Widget>[
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('How the courses split'),
              CourseSplitChoice(
                grouped: _byCourse,
                source: 'sheet',
                onChanged: (bool grouped) => setState(() {
                  _byCourse = grouped;
                  _weighByBlocks = grouped;
                }),
              ),
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

/// Shown for as long as the AI check runs, which is not quick.
///
/// It names the wait rather than just spinning: a minute of an unexplained
/// spinner on a screen that was already saying "Reading..." reads as a hang,
/// and the one thing the student can usefully know is that it is worth waiting.
class _CheckingDialog extends StatelessWidget {
  const _CheckingDialog();

  @override
  Widget build(BuildContext context) {
    // The system back gesture would otherwise dismiss this and leave the call
    // running with nothing on screen.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: <Widget>[
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'Checking with AI',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'A dense sheet can take a minute or two.',
                    style: TextStyle(color: context.palette.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FormatHelp extends StatelessWidget {
  const _FormatHelp({required this.grid});

  final DayGrid grid;

  @override
  Widget build(BuildContext context) {
    return GroupNote(
      'One class per line: subject, day, blocks, room, professor. The room '
      'and professor can be left off. A lab across two periods is "1-2". '
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

/// Names the recogniser may have read two ways. A warning, not a problem: two
/// rooms really can be a digit apart, so it never blocks the import.
class _OddNameRow extends StatelessWidget {
  const _OddNameRow({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Text(
        name,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _LookalikeRow extends StatelessWidget {
  const _LookalikeRow({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        names.join('  ·  '),
        style: TextStyle(
          fontSize: 13,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          color: context.palette.cancelled,
        ),
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
