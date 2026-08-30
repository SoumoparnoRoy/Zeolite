import '../../domain/notion/notion_mapping.dart';
import '../../domain/notion/notion_page_rows.dart';
import '../../domain/notion/notion_properties.dart';
import '../../domain/notion_export.dart';
import '../../domain/sync/sync_target.dart';
import 'notion_client.dart';

/// A database read once, ready to be turned into rows either way.
///
/// Both answers to the keyed-rows question come off the same pages, so it can
/// be put to the user after the read rather than before.
class NotionSource {
  NotionSource({
    required NotionMapping mapping,
    required List<Map<String, Object?>> pages,
    required Map<String, String> courseNames,
  })  : _rows = NotionPageRows(mapping),
        _pages = pages,
        _courseNames = courseNames;

  final NotionPageRows _rows;
  final List<Map<String, Object?>> _pages;
  final Map<String, String> _courseNames;

  int get length => _pages.length;

  NotionExport read({required bool skipKeyed}) => _rows.read(
        _pages,
        courseNames: _courseNames,
        skipKeyed: skipKeyed,
      );

  bool get hasKeyedRows => _rows.hasKeyed(_pages);
}

/// A read that either produced a database or the reason it did not.
class NotionReadResult {
  const NotionReadResult.done(NotionSource this.source) : failure = null;

  const NotionReadResult.failed(this.failure) : source = null;

  final NotionSource? source;
  final SyncFailure? failure;
}

/// Pulls a mapped data source down for the import preview.
///
/// Separate from `NotionSyncTarget`, whose read deliberately drops everything
/// with no `Zeolite ID` because nothing there could be matched to a mark. This
/// one wants exactly those rows.
class NotionDatabaseReader {
  const NotionDatabaseReader({
    required NotionClient client,
    required NotionMapping mapping,
  })  : _client = client,
        _mapping = mapping;

  final NotionClient _client;
  final NotionMapping _mapping;

  Future<NotionReadResult> read() async {
    final NotionRows rows = await _client.queryAllPages(_mapping.dataSourceId);
    if (!rows.ok) {
      return NotionReadResult.failed(rows.failure ?? SyncFailure.unknown);
    }

    final NotionPageRows pageRows = NotionPageRows(_mapping);
    final Map<String, String> courseNames = <String, String>{};
    // One read per distinct course, not per row. A course that will not load
    // leaves its own rows to be reported as unnamed rather than failing an
    // import over one page.
    for (final String id in pageRows.relatedCourseIds(rows.pages)) {
      final String? title = _titleOf((await _client.page(id)).body);
      if (title != null) courseNames[id] = title;
    }

    return NotionReadResult.done(
      NotionSource(
        mapping: _mapping,
        pages: rows.pages,
        courseNames: courseNames,
      ),
    );
  }

  /// A page's own name, which is whichever of its properties is the title.
  static String? _titleOf(Map<String, Object?>? page) {
    final Object? properties = page?['properties'];
    if (properties is! Map<String, Object?>) return null;
    for (final Object? value in properties.values) {
      if (value is Map<String, Object?> && value['type'] == 'title') {
        return NotionProperties.plainTextOf(value);
      }
    }
    return null;
  }
}
