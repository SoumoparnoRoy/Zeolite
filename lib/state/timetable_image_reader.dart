import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/attendance_totals_ocr.dart';
import '../domain/grid_lines.dart';
import '../domain/timetable_choices.dart';
import '../domain/timetable_ocr.dart';
import '../domain/vision_merge.dart';
import '../domain/vision_read.dart';
import '../services/image_edges.dart';
import '../services/text_recognition.dart';
import '../services/timetable/vision_client.dart';
import 'app_providers.dart';

/// What a photo turned out to hold.
sealed class SheetRead {
  const SheetRead();
}

/// A portal's attendance page rather than a timetable. Null [totals] means
/// it was recognised but no course rows came off it.
final class TotalsSheet extends SheetRead {
  const TotalsSheet(this.totals);

  final AttendanceTotals? totals;
}

final class NoClassesFound extends SheetRead {
  const NoClassesFound({required this.gridFound});

  /// The weekdays and period times were readable, but no class was.
  final bool gridFound;
}

final class TimetableSheet extends SheetRead {
  const TimetableSheet({
    required this.grid,
    required this.entries,
    required this.lines,
    required this.confident,
  });

  final TimetableGrid? grid;
  final List<OcrEntry> entries;

  /// The whole page's best read, which is what a second opinion is shown.
  final List<OcrLine> lines;
  final bool confident;
}

class AiCheck {
  const AiCheck({required this.entries, this.failure, this.added = 0});

  /// The read as it stands afterwards: untouched on every failure.
  final List<OcrEntry> entries;
  final VisionFailure? failure;
  final int added;
}

/// A read tidied into lines, with what is left to ask the student.
class PreparedSheet {
  const PreparedSheet({
    required this.entries,
    required this.joined,
    required this.axes,
    required this.baskets,
  });

  final List<OcrEntry> entries;

  /// Two boxes became one class somewhere.
  final bool joined;

  /// Only the axes that actually offer a choice.
  final Map<String, List<String>> axes;
  final List<ElectiveBasket> baskets;

  bool get asks => axes.isNotEmpty || baskets.isNotEmpty;
}

final timetableImageReaderProvider = Provider<TimetableImageReader>(
  TimetableImageReader.new,
);

/// Reading a timetable off a photo, on the device first and by a model only
/// when asked.
class TimetableImageReader {
  TimetableImageReader(this.ref);

  final Ref ref;

  /// The widest the copy that leaves the device is drawn. Past this is tokens
  /// spent on detail the model tiles away.
  static const int _sentWidth = 1600;

  /// Null when the student backed out of the picker.
  Future<Uint8List?> pickImage() async {
    final PlatformFile? picked = await FilePicker.pickFile();
    return picked?.readAsBytes();
  }

  Future<SheetRead> read(Uint8List bytes) async {
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
      return TotalsSheet(
        totals == null || totals.rows.isEmpty ? null : totals,
      );
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
      return NoClassesFound(gridFound: best.grid != null);
    }
    return TimetableSheet(
      grid: best.grid,
      entries: best.entries,
      lines: lines,
      confident: TimetableOcr.confidenceOf(best.grid, best.entries).isConfident,
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

  /// Asks a model what it sees, and folds anything new into the local read.
  /// Only ever called once the student has agreed to send the image.
  Future<AiCheck> checkWithAi(TimetableSheet sheet, Uint8List bytes) async {
    final VisionClient client = ref.read(visionClientProvider);
    final VisionRead read = await client.read(
      image: await TextRecognition.narrowedTo(bytes, _sentWidth),
      text: <String>[for (final OcrLine l in sheet.lines) l.text].join('\n'),
    );
    if (!read.ok) return AiCheck(entries: sheet.entries, failure: read.failure);

    final List<OcrEntry> found = VisionMerge.corroboratedBy(
      sheet.grid!,
      sheet.lines,
      VisionMerge.placedOn(sheet.grid!, read.classes),
    );
    final List<OcrEntry> merged = VisionMerge.filling(sheet.entries, found);
    return AiCheck(
      entries: merged,
      added: merged.length - sheet.entries.length,
    );
  }

  static PreparedSheet prepare(List<OcrEntry> read) {
    final List<OcrEntry> mended = TimetableOcr.withCodesMended(read);
    final List<OcrEntry> entries = TimetableOcr.joinedRuns(mended);
    return PreparedSheet(
      entries: entries,
      joined: entries.length < mended.length,
      axes: <String, List<String>>{
        for (final MapEntry<String, List<String>> axis
            in TimetableOcr.groupAxesIn(entries).entries)
          if (axis.value.length > 1) axis.key: axis.value,
      },
      baskets: TimetableOcr.basketsIn(entries),
    );
  }

  /// One line per class, the ones the student's answers leave out behind a
  /// `#`, which the parser already skips — so answering wrong costs a deleted
  /// character rather than another read of the image.
  static List<String> linesFor(
    List<OcrEntry> entries,
    TimetableChoices choices,
  ) =>
      <String>[
        for (final OcrEntry e in entries)
          if (choices.keeps(e)) e.toLine() else '# ${e.toLine()}',
      ];
}
