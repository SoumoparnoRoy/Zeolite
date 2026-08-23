import '../data/models/subject.dart';
import 'attendance_totals_ocr.dart';

/// What importing one row would do to the database.
enum TotalsMatch {
  /// No subject of that name — it would be created.
  create,

  /// A subject of that name exists and has nothing marked against it, so its
  /// three numbers can simply be replaced.
  update,

  /// A subject of that name exists **and** has been marked in the app. The
  /// portal's figures already include those classes, so replacing the balance
  /// without dropping the marks would count them twice.
  overlap,
}

/// One row of the portal page, resolved against what is already stored.
class TotalsPlanRow {
  const TotalsPlanRow({
    required this.row,
    required this.subject,
    required this.marksInTerm,
  });

  final TotalsRow row;

  /// The subject this row matched on name, if any.
  final Subject? subject;

  /// Marks recorded in this app for that subject this term.
  final int marksInTerm;

  TotalsMatch get match {
    if (subject == null) return TotalsMatch.create;
    return marksInTerm > 0 ? TotalsMatch.overlap : TotalsMatch.update;
  }

  /// What the subject reads today, for the preview to show beside the new
  /// figures. Null for a subject that does not exist yet.
  String? get current {
    final Subject? existing = subject;
    if (existing == null) return null;
    final int held = existing.priorHeld + marksInTerm;
    return '${existing.priorAttended} of $held';
  }
}

/// Every row of a portal page resolved against the stored subjects.
///
/// Matching is on the name alone, lowercased and trimmed: a portal page has no
/// codes on it, and the name is what the earlier paste import already keys on.
class TotalsPlan {
  const TotalsPlan(this.rows);

  final List<TotalsPlanRow> rows;

  static TotalsPlan from({
    required List<TotalsRow> rows,
    required List<Subject> subjects,
    required Map<int, int> marksBySubject,
  }) {
    final Map<String, Subject> byName = <String, Subject>{
      for (final Subject subject in subjects)
        subject.name.trim().toLowerCase(): subject,
    };

    return TotalsPlan(<TotalsPlanRow>[
      for (final TotalsRow row in rows)
        () {
          final Subject? match = byName[row.subject.trim().toLowerCase()];
          return TotalsPlanRow(
            row: row,
            subject: match,
            marksInTerm:
                match?.id == null ? 0 : (marksBySubject[match!.id!] ?? 0),
          );
        }(),
    ]);
  }

  int countOf(TotalsMatch match) =>
      rows.where((TotalsPlanRow r) => r.match == match).length;

  List<TotalsPlanRow> get overlaps =>
      rows.where((TotalsPlanRow r) => r.match == TotalsMatch.overlap).toList();

  List<TotalsPlanRow> get suspect =>
      rows.where((TotalsPlanRow r) => !r.row.isTrustworthy).toList();
}

/// One row the user has agreed to import, and how.
class TotalsDecision {
  const TotalsDecision({
    required this.row,
    this.subjectId,
    this.clearMarks = false,
  });

  final TotalsRow row;

  /// The subject to write onto, or null to create one.
  final int? subjectId;

  /// Whether this subject's marks for the term go — see [TotalsMatch.overlap].
  final bool clearMarks;
}
