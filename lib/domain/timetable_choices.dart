import 'timetable_ocr.dart';

/// Which of a division-wide sheet's alternatives are one student's.
///
/// A sheet printed for a division offers more classes than anybody attends:
/// labs split by batch, tutorials by group, and periods that are a choice
/// between several courses.
class TimetableChoices {
  const TimetableChoices({
    required this.baskets,
    this.groups = const <String>{},
    this.electives = const <int, String>{},
  });

  /// Answers in [electives] are keyed by position in this list.
  final List<ElectiveBasket> baskets;

  /// The chosen marker on each axis that was answered — `B1`, `G2`.
  final Set<String> groups;

  final Map<int, String> electives;

  bool get isEmpty => groups.isEmpty && electives.isEmpty;

  /// An unanswered question keeps all of its alternatives rather than none, so
  /// skipping one costs a longer list to edit and never a missing class.
  bool keeps(OcrEntry entry) {
    final String? group = entry.group;
    if (group != null && _answered(group) && !groups.contains(group)) {
      return false;
    }
    for (int i = 0; i < baskets.length; i++) {
      final String? mine = electives[i];
      if (mine == null || !baskets[i].holds(entry)) continue;
      if (entry.subject != mine) return false;
    }
    return true;
  }

  /// Whether the axis [group] belongs to was answered at all. The letter is
  /// the axis, so answering `B1` says nothing about a `G` marker.
  bool _answered(String group) =>
      groups.any((String g) => g[0] == group[0]);
}
