import '../../domain/notion/notion_claim.dart';
import '../../domain/notion/notion_course.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../domain/notion/notion_page_rows.dart';
import '../../domain/notion/notion_properties.dart';
import '../../domain/sync/sync_target.dart';
import 'notion_client.dart';
import 'notion_courses_writer.dart';
import 'notion_database_reader.dart';

/// A Notion data source as somewhere attendance can be mirrored to.
///
/// Only attendance: a workspace holds classes as rows, and nothing here knows
/// what a room or a settings row would even be.
class NotionSyncTarget implements SyncTarget {
  NotionSyncTarget({
    required NotionClient client,
    required NotionMapping mapping,
    required NotionCourse? Function(String subjectUuid) course,
    String? Function(String subjectUuid)? categoryName,
    bool cancelledCounts = false,
  })  : _client = client,
        _mapping = mapping,
        _course = course,
        _categoryName = categoryName,
        _properties =
            NotionProperties(mapping, cancelledCounts: cancelledCounts),
        _courses = mapping.courses == null
            ? null
            : NotionCoursesWriter(
                client: client,
                courses: mapping.courses!,
              );

  final NotionClient _client;
  final NotionMapping _mapping;
  final NotionProperties _properties;

  /// A mark names its subject by uuid, which means nothing in a workspace.
  final NotionCourse? Function(String subjectUuid) _course;

  /// Null unless the workspace has a Courses table to relate marks into.
  final NotionCoursesWriter? _courses;

  /// What kind of session the subject holds, for Notion's `Type`.
  final String? Function(String subjectUuid)? _categoryName;

  /// Stored in `remote_links.target`, so it has to stay stable once shipped.
  static const String targetId = 'notion';

  @override
  String get id => targetId;

  // A page that has gone was removed by hand, and putting it back would
  // override that.
  @override
  bool get recreatesMissingRows => false;

  /// A person edits these rows by hand, so a pull is somebody's typing and
  /// goes through the import preview rather than straight into the database.
  @override
  bool get trustsPulls => false;

  /// The table is theirs, and a row this app stops holding may be one they
  /// still want in front of them.
  @override
  bool get ownsEveryRow => false;

  @override
  Set<SyncKind> get kinds => const <SyncKind>{SyncKind.attendance};

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

    // A run starts here, and course pages made in Notion since the last one
    // have to be seen rather than duplicated.
    _courses?.forget();

    _unkeyed = const <Map<String, Object?>>[];
    _claimed.clear();
    final NotionRows rows = await _client.queryAllPages(_mapping.dataSourceId);
    if (!rows.ok) return null;

    final List<RemoteState> found = <RemoteState>[];
    final List<Map<String, Object?>> unkeyed = <Map<String, Object?>>[];
    for (final Map<String, Object?> page in rows.pages) {
      // Null is a row somebody made by hand. It is only ever taken for a mark
      // by [claim], which knows the marks; filing it by itself here would put
      // it against a class it may have nothing to do with.
      final RemoteState? state = _properties.decode(page);
      if (state != null) {
        found.add(state);
      } else if (page['id'] is String) {
        unkeyed.add(page);
      }
    }
    _unkeyed = unkeyed;
    return found;
  }

  /// This run's pages with no key, kept from [fetch] so a claim costs no
  /// second read of the table.
  List<Map<String, Object?>> _unkeyed = const <Map<String, Object?>>[];

  /// Pages claimed this run, so [update] writes nothing but the key into one.
  final Set<String> _claimed = <String>{};

  /// A row made by hand is the mark the import made from it, until the key
  /// column exists and nothing yet says so. Pairing them here is what stops
  /// the first run after adding the column filing every class twice.
  @override
  Future<List<SyncClaim>> claim(
    SyncKind kind,
    List<SyncItem> unlinked,
  ) async {
    final List<Map<String, Object?>> pages = _unkeyed;
    if (kind != SyncKind.attendance || pages.isEmpty) {
      return const <SyncClaim>[];
    }

    final NotionPageRows reader = NotionPageRows(_mapping);
    final Map<String, String> courseNames = <String, String>{};
    for (final String id in reader.relatedCourseIds(pages)) {
      final String? title =
          NotionDatabaseReader.titleOf((await _client.page(id)).body);
      if (title != null) courseNames[id] = title;
    }

    final Map<String, SyncItem> markByKey = <String, SyncItem>{
      for (final SyncItem item in unlinked) item.localKey: item,
    };
    final Map<String, String> paired = NotionClaim.pair(
      rows: reader.unkeyed(pages, courseNames: courseNames),
      marks: unlinked,
      subjectName: (String uuid) => _course(uuid)?.name,
    );
    final Map<String, Map<String, Object?>> byId =
        <String, Map<String, Object?>>{
      for (final Map<String, Object?> page in pages)
        page['id']! as String: page,
    };

    final List<SyncClaim> claimed = <SyncClaim>[];
    for (final MapEntry<String, String> pair in paired.entries) {
      final RemoteState state =
          _properties.stateOf(byId[pair.value]!, pair.key);
      final bool agrees =
          state.hash == _properties.remoteHashFor(markByKey[pair.key]!);
      if (agrees) _claimed.add(state.remoteId);
      claimed.add(SyncClaim(state: state, agrees: agrees));
    }
    return claimed;
  }

  /// Refused rather than pushed when nothing can identify a row again.
  ///
  /// Without the key column [fetch] returns null, so the planner never sees
  /// what the table already holds and every run files the same mark as a new
  /// page — which is somebody's workspace filling with duplicates the app
  /// cannot even find to clean up. The mapping screen offers to add the
  /// column; until it exists, not writing is the only honest answer.
  bool get _canBeFoundAgain => _mapping.fields.containsKey(NotionField.key);

  static const String _noKeyColumn =
      'Add the Zeolite ID column before syncing, or every class is written '
      'again on every run.';

  @override
  Future<SyncOutcome> create(SyncItem item) async {
    if (!_canBeFoundAgain) {
      return const SyncOutcome.failed(
        SyncFailure.rejected,
        message: _noKeyColumn,
      );
    }
    final NotionResult result = await _client.createPage(
      dataSourceId: _mapping.dataSourceId,
      properties: await _encode(item),
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
    if (!_canBeFoundAgain) {
      return const SyncOutcome.failed(
        SyncFailure.rejected,
        message: _noKeyColumn,
      );
    }
    // A claimed row takes the key alone. One that disagrees with the mark
    // never reaches here: it goes to review, and comes back with a link.
    final bool keyOnly = _claimed.remove(remoteId);
    final NotionResult result = await _client.updatePage(
      remoteId,
      keyOnly ? _properties.keyOnly(item.localKey) : await _encode(item),
    );
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

  Future<Map<String, Object?>> _encode(SyncItem item) async {
    final String uuid = _subjectOf(item.localKey);
    final NotionCourse? course = _course(uuid);
    return _properties.encode(
      item,
      courseName: course?.name,
      categoryName: _categoryName?.call(uuid),
      courseRelationId:
          course == null ? null : await _courses?.pageIdFor(course),
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
