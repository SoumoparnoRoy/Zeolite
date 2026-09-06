import 'notion_client.dart';

/// Retiring a template the user has moved off.
///
/// A template ships two related databases, so what Notion duplicates is a
/// *page* holding them — and trashing the attendance database alone left the
/// Courses table and the page behind.
class NotionTemplateRetirement {
  const NotionTemplateRetirement(this._client);

  final NotionClient _client;

  /// The page a template's databases live in, or null when there is not one.
  /// Without a stored [knownPageId], Notion is asked for the parent.
  Future<String?> pageOf({
    required String databaseId,
    String? knownPageId,
  }) async {
    if (knownPageId != null && knownPageId.isNotEmpty) return knownPageId;

    final NotionResult database = await _client.database(databaseId);
    final Object? parent = database.body?['parent'];
    if (parent is! Map<String, Object?> || parent['type'] != 'page_id') {
      return null;
    }
    final String? id = parent['page_id'] as String?;
    return id != null && id.isNotEmpty ? id : null;
  }

  /// Renames what the user actually reads in their sidebar.
  ///
  /// The page carries the template's name and the table inside it carries its
  /// own, so renaming the table left two pages with the same name — which is
  /// the thing a rename exists to prevent.
  Future<NotionRename> rename({
    required String databaseId,
    required String databaseTitle,
    String? pageId,
  }) async {
    if (pageId == null || pageId.isEmpty) {
      final String name = '$databaseTitle (old)';
      return NotionRename(
        await _client.renameDatabase(databaseId, name),
        name,
      );
    }

    // Read first, because the name to append to is the page's own.
    final NotionResult page = await _client.page(pageId);
    final String name = '${_titleOf(page.body) ?? databaseTitle} (old)';
    return NotionRename(await _client.renamePage(pageId, name), name);
  }

  /// A page's name lives in whichever property is the title one — not the
  /// shape a database's name comes back in.
  static String? _titleOf(Map<String, Object?>? body) {
    final Object? properties = body?['properties'];
    if (properties is! Map<String, Object?>) return null;
    for (final Object? property in properties.values) {
      if (property is! Map<String, Object?>) continue;
      if (property['type'] != 'title') continue;
      final Object? parts = property['title'];
      if (parts is! List<Object?>) continue;
      final String joined = parts
          .whereType<Map<String, Object?>>()
          .map((Map<String, Object?> part) => part['plain_text'])
          .whereType<String>()
          .join();
      if (joined.isNotEmpty) return joined;
    }
    return null;
  }

  /// Courses goes only after the attendance table actually went: a
  /// half-retired template is worse than an untouched one.
  Future<NotionResult> trash({
    required String databaseId,
    String? pageId,
    String? coursesDatabaseId,
  }) async {
    if (pageId != null && pageId.isNotEmpty) {
      return _client.trashPage(pageId);
    }

    // Nothing above them, so the tables are all there is to take.
    final NotionResult result = await _client.trashDatabase(databaseId);
    if (result.ok && coursesDatabaseId != null && coursesDatabaseId.isNotEmpty) {
      await _client.trashDatabase(coursesDatabaseId);
    }
    return result;
  }
}

/// What a rename did and the name it settled on, which the caller both says
/// back to the user and stores.
class NotionRename {
  const NotionRename(this.result, this.title);

  final NotionResult result;
  final String title;
}
