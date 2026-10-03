import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/notion/notion_mapping.dart';
import '../services/notion/notion_client.dart';
import '../services/notion/notion_connection_store.dart';
import '../services/notion/notion_template_retirement.dart';
import 'notion_providers.dart';

final notionRetirementActionsProvider = Provider<NotionRetirementActions>(
  NotionRetirementActions.new,
);

/// What happens to a table left behind by taking the template again.
///
/// The prompts live with the screen; this is everything they decide, so the
/// store and the list Settings shows never disagree with what Notion holds.
class NotionRetirementActions {
  NotionRetirementActions(this.ref);

  final Ref ref;

  NotionTemplateRetirement get _retirement =>
      NotionTemplateRetirement(ref.read(notionClientProvider));

  NotionConnectionStore get _store => ref.read(notionConnectionStoreProvider);

  /// The page the table came in, which decides what a prompt can honestly
  /// say is going: the page, or only the one table inside it.
  Future<String?> pageOf(String databaseId, {String? knownPageId}) =>
      _retirement.pageOf(databaseId: databaseId, knownPageId: knownPageId);

  /// Remembered so the offer outlives the moment it was made: Settings keeps
  /// a way back until it is dealt with.
  Future<void> defer(NotionMapping before, String? page) async {
    await _store.writeRetired(before.databaseId, before.title, pageId: page);
    ref.invalidate(retiredNotionDatabasesProvider);
  }

  Future<NotionRename> rename(NotionMapping before, String? page) async {
    final NotionRename renamed = await _retirement.rename(
      databaseId: before.databaseId,
      databaseTitle: before.title,
      pageId: page,
    );
    // Stored from what the rename settled on rather than rebuilt here: the
    // page's name is not the table's, so the two would not agree.
    await _store.writeRetired(
      before.databaseId,
      renamed.result.ok ? renamed.title : before.title,
      pageId: page,
    );
    ref.invalidate(retiredNotionDatabasesProvider);
    return renamed;
  }

  Future<bool> trash(NotionMapping before, String? page) async {
    final NotionResult result = await _retirement.trash(
      databaseId: before.databaseId,
      pageId: page,
      coursesDatabaseId: before.courses?.databaseId,
    );
    if (result.ok) {
      // Only this one: an offer still open for a different page is not ours
      // to answer here.
      await _store.removeRetired(before.databaseId);
      ref.invalidate(retiredNotionDatabasesProvider);
    }
    return result.ok;
  }

  /// How many of [pages] went.
  ///
  /// Sequentially, and through a failure rather than stopping at it: the
  /// alternative leaves an arbitrary subset done with no way to tell which.
  Future<int> trashRetired(Map<RetiredNotionDatabase, String?> pages) async {
    int moved = 0;
    for (final MapEntry<RetiredNotionDatabase, String?> old in pages.entries) {
      final NotionResult result = await _retirement.trash(
        databaseId: old.key.id,
        pageId: old.value,
      );
      // Already gone is the outcome that was asked for, so the row goes too.
      if (result.ok || result.isNotFound) {
        moved++;
        await _store.removeRetired(old.key.id);
      }
    }
    ref.invalidate(retiredNotionDatabasesProvider);
    return moved;
  }
}
