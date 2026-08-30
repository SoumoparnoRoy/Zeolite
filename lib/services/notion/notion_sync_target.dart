import '../../domain/notion/notion_mapping.dart';
import '../../domain/notion/notion_properties.dart';
import '../../domain/sync/sync_target.dart';
import 'notion_client.dart';

/// A Notion data source as somewhere attendance can be mirrored to.
///
/// Only attendance: a workspace holds classes as rows, and nothing here knows
/// what a room or a settings row would even be.
class NotionSyncTarget implements SyncTarget {
  NotionSyncTarget({
    required NotionClient client,
    required NotionMapping mapping,
    required String? Function(String subjectUuid) courseName,
    String? Function(String subjectUuid)? categoryName,
  })  : _client = client,
        _mapping = mapping,
        _courseName = courseName,
        _categoryName = categoryName,
        _properties = NotionProperties(mapping);

  final NotionClient _client;
  final NotionMapping _mapping;
  final NotionProperties _properties;

  /// A mark names its subject by uuid, which means nothing in a workspace.
  final String? Function(String subjectUuid) _courseName;

  /// What kind of session the subject holds, for Notion's `Type`.
  final String? Function(String subjectUuid)? _categoryName;

  /// Stored in `remote_links.target`, so it has to stay stable once shipped.
  static const String targetId = 'notion';

  @override
  String get id => targetId;

  /// A person edits these rows by hand, so a pull is somebody's typing and
  /// goes through the import preview rather than straight into the database.
  @override
  bool get trustsPulls => false;

  @override
  Set<SyncKind> get kinds => const <SyncKind>{SyncKind.attendance};

  /// How many pages one query returns before the cursor is followed again.
  static const int _pageSize = 100;

  /// A run stops walking after this many pages rather than pulling a whole
  /// workspace into memory on a database somebody else fills too.
  static const int _maxPages = 20;

  /// What the table holds now, or null when it cannot be read.
  ///
  /// Null is also the honest answer for a database with no key column: the
  /// planner treats it as an unread far side and pushes without claiming to
  /// know anything, which is right — nothing in Notion could be matched back
  /// to a mark, so reporting an empty table would delete every link instead.
  @override
  Future<List<RemoteState>?> fetch(SyncKind kind) async {
    if (kind != SyncKind.attendance) return null;
    if (!_mapping.fields.containsKey(NotionField.key)) return null;

    final List<RemoteState> found = <RemoteState>[];
    String? cursor;
    for (int page = 0; page < _maxPages; page++) {
      final NotionResult result = await _client.queryDataSource(
        _mapping.dataSourceId,
        cursor: cursor,
        pageSize: _pageSize,
      );
      if (!result.ok) return null;

      final Object? rows = result.body?['results'];
      if (rows is List<Object?>) {
        for (final Object? row in rows) {
          if (row is! Map<String, Object?>) continue;
          // Null is a row somebody made by hand, which belongs to the import
          // screen; adopting it here would file it against a class it may
          // have nothing to do with.
          final RemoteState? state = _properties.decode(row);
          if (state != null) found.add(state);
        }
      }

      if (result.body?['has_more'] != true) break;
      cursor = result.body?['next_cursor'] as String?;
      if (cursor == null) break;
    }
    return found;
  }

  @override
  Future<SyncOutcome> create(SyncItem item) async {
    final NotionResult result = await _client.createPage(
      dataSourceId: _mapping.dataSourceId,
      properties: _encode(item),
    );
    final String? id = result.body?['id'] as String?;
    if (!result.ok || id == null) return _failure(result);
    return SyncOutcome.done(
      remoteId: id,
      remoteHash: _properties.remoteHashFor(item),
    );
  }

  @override
  Future<SyncOutcome> update(SyncItem item, String remoteId) async {
    final NotionResult result =
        await _client.updatePage(remoteId, _encode(item));
    if (!result.ok) return _failure(result);
    return SyncOutcome.done(
      remoteId: remoteId,
      remoteHash: _properties.remoteHashFor(item),
    );
  }

  /// Trashed rather than deleted, so the user can get the page back.
  ///
  /// A page that is already gone counts as done: the mark was removed here,
  /// somebody removed it there, and retrying every run forever would be the
  /// only thing that changed.
  @override
  Future<SyncOutcome> archive(SyncKind kind, String remoteId) async {
    final NotionResult result = await _client.trashPage(remoteId);
    if (result.ok || result.message == 'object_not_found') {
      return SyncOutcome.done(remoteId: remoteId, remoteHash: _gone);
    }
    return _failure(result);
  }

  Map<String, Object?> _encode(SyncItem item) {
    final String subject = _subjectOf(item.localKey);
    return _properties.encode(
      item,
      courseName: _courseName(subject),
      categoryName: _categoryName?.call(subject),
    );
  }

  /// `uuid:20260304:540`.
  static String _subjectOf(String localKey) => localKey.split(':').first;

  static SyncOutcome _failure(NotionResult result) =>
      SyncOutcome.failed(result.failure ?? SyncFailure.unknown,
          message: result.message);

  /// One value for every removal, so a page that has gone reads as changed
  /// exactly once.
  static const String _gone = 'trashed';
}
