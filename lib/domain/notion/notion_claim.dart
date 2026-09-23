import '../../core/date_utils.dart';
import '../notion_export.dart';
import '../sync/sync_target.dart';
import 'notion_page_rows.dart';

/// Pairs rows somebody kept by hand with the marks that stand for them, so a
/// table filled in before it had a `Zeolite ID` column is keyed rather than
/// copied.
///
/// A row is only ever paired with a mark of the same subject on the same day
/// that nothing else links. That is the whole claim: a hand-made row on a day
/// the app has no such mark for stays the import screen's business.
class NotionClaim {
  const NotionClaim._();

  /// Mark key to page id. [subjectName] names a mark's subject by its uuid.
  static Map<String, String> pair({
    required List<NotionUnkeyedRow> rows,
    required List<SyncItem> marks,
    required String? Function(String subjectUuid) subjectName,
  }) {
    final Map<String, List<_Mark>> marksByDay = <String, List<_Mark>>{};
    for (final SyncItem item in marks) {
      final List<String> parts = item.localKey.split(':');
      if (parts.length != 3) continue;
      final String? name = subjectName(parts[0]);
      final int? day = int.tryParse(parts[1]);
      final int? start = int.tryParse(parts[2]);
      if (name == null || day == null || start == null) continue;
      marksByDay.putIfAbsent(_dayKey(name, day), () => <_Mark>[]).add(
            _Mark(item.localKey, start, item.fields['status'] as String?),
          );
    }
    for (final List<_Mark> day in marksByDay.values) {
      day.sort((_Mark a, _Mark b) => a.start.compareTo(b.start));
    }
    final Set<String> subjects = <String>{
      for (final String key in marksByDay.keys) key.split('|').first,
    };

    final Map<String, String> out = <String, String>{};
    final Set<String> used = <String>{};

    // The name the import would have given this row first. A practical falls
    // back to its bare course only where no subject carries the lab's name,
    // which is how a grouped import filed it.
    for (final bool asImported in <bool>[true, false]) {
      final Map<String, List<NotionUnkeyedRow>> rowsByDay =
          <String, List<NotionUnkeyedRow>>{};
      for (final NotionUnkeyedRow unkeyed in rows) {
        if (used.contains(unkeyed.pageId)) continue;
        final NotionRow row = unkeyed.row;
        final String named = row.kind.subjectName(row.course);
        if (!asImported &&
            (named == row.course || subjects.contains(_nameKey(named)))) {
          continue;
        }
        final String day =
            _dayKey(asImported ? named : row.course, Dates.keyOf(row.date));
        rowsByDay.putIfAbsent(day, () => <NotionUnkeyedRow>[]).add(unkeyed);
      }

      for (final MapEntry<String, List<NotionUnkeyedRow>> entry
          in rowsByDay.entries) {
        final List<_Mark>? day = marksByDay[entry.key];
        if (day == null || day.isEmpty) continue;
        _pairDay(entry.value, day, out, used);
      }
    }
    return out;
  }

  /// A time the row states wins, then a matching status, then order — which
  /// can only misfile two classes of one subject on one day that disagree,
  /// and the app's own mark is what gets written over either of them.
  static void _pairDay(
    List<NotionUnkeyedRow> rows,
    List<_Mark> marks,
    Map<String, String> out,
    Set<String> used,
  ) {
    void take(NotionUnkeyedRow row, _Mark mark) {
      out[mark.key] = row.pageId;
      used.add(row.pageId);
      marks.remove(mark);
    }

    for (final NotionUnkeyedRow row in rows) {
      final int? start = row.row.startMinutes;
      if (start == null) continue;
      final _Mark? mark =
          marks.where((_Mark m) => m.start == start).firstOrNull;
      if (mark != null) take(row, mark);
    }
    for (final NotionUnkeyedRow row in rows) {
      if (used.contains(row.pageId)) continue;
      final _Mark? mark = marks
          .where((_Mark m) => m.status == row.row.status.name)
          .firstOrNull;
      if (mark != null) take(row, mark);
    }
    for (final NotionUnkeyedRow row in rows) {
      if (used.contains(row.pageId) || marks.isEmpty) continue;
      take(row, marks.first);
    }
  }

  static String _nameKey(String name) => name.trim().toLowerCase();

  static String _dayKey(String name, int day) => '${_nameKey(name)}|$day';
}

class _Mark {
  _Mark(this.key, this.start, this.status);

  final String key;
  final int start;
  final String? status;
}
