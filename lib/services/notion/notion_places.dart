import 'notion_client.dart';

/// Where a table sits, as the page a person would recognise it by.
///
/// Two tables of one name — a copy and the one it was copied from — read the
/// same in any list of tables, and the page holding each is what tells them
/// apart.
class NotionPlaces {
  NotionPlaces(this._client);

  final NotionClient _client;
  final Map<String, Future<String?>> _pageTitles = <String, Future<String?>>{};

  /// The name of the page [databaseId] lives in, or null when it sits at the
  /// top of the workspace or cannot be read.
  Future<String?> pageTitleOf(String databaseId) async {
    final NotionResult database = await _client.database(databaseId);
    if (!database.ok) return null;
    final String? page = await pageAbove(database.body?['parent']);
    if (page == null) return null;
    // Tables sharing a page are common, and a page is read once.
    return _pageTitles.putIfAbsent(page, () async {
      final NotionResult read = await _client.page(page);
      return read.ok ? titleOf(read.body) : null;
    });
  }

  static const int _maxHops = 4;

  /// Walks up to the page something sits in. Notion reports an *inline*
  /// database's parent as the block holding it rather than as a page, so
  /// checking only for `page_id` left the whole template behind. That block is
  /// the page itself when the database sits directly in one; deeper it is not,
  /// hence a chain rather than an assumption.
  Future<String?> pageAbove(Object? from) async {
    Object? parent = from;
    for (int hop = 0; hop < _maxHops; hop++) {
      if (parent is! Map<String, Object?>) return null;

      if (parent['type'] == 'page_id') {
        final String? id = parent['page_id'] as String?;
        return id != null && id.isNotEmpty ? id : null;
      }
      if (parent['type'] != 'block_id') return null;

      final String? id = parent['block_id'] as String?;
      if (id == null || id.isEmpty) return null;
      final NotionResult block = await _client.block(id);
      if (!block.ok) return null;
      // A page is a block too, and this is how it says so.
      if (block.body?['type'] == 'child_page') return id;
      parent = block.body?['parent'];
    }
    return null;
  }

  /// A page's name lives in whichever property is the title one — not the
  /// shape a database's name comes back in.
  static String? titleOf(Map<String, Object?>? body) {
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
}
