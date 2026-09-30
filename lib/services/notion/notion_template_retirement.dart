import 'notion_client.dart';
import 'notion_places.dart';

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
    return NotionPlaces(_client).pageAbove(database.body?['parent']);
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
    final String name =
        '${NotionPlaces.titleOf(page.body) ?? databaseTitle} (old)';
    return NotionRename(await _client.renamePage(pageId, name), name);
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
    if (result.ok &&
        coursesDatabaseId != null &&
        coursesDatabaseId.isNotEmpty) {
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
