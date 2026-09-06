import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../services/notion/notion_client.dart';
import '../../services/notion/notion_connection_store.dart';
import '../../services/notion/notion_template_retirement.dart';
import '../../services/sync/sync_coordinator.dart';
import '../../state/notion_providers.dart';
import '../../state/notion_sync_providers.dart';
import 'notion_connect_screen.dart';
import 'notion_mapping_gaps.dart';

/// What the user chose to do with the database they moved off.
enum _OldDatabase { keep, rename, trash }

/// Moving to a newer version of the template Notion hands out at consent.
///
/// The app cannot create a database, so a new schema only ever arrives by
/// taking the template again — which produces a *second* database rather than
/// changing the first. The old one is therefore still full of the user's rows
/// when this finishes, and what happens to it is their call, not ours.
class NotionTemplateMigration {
  const NotionTemplateMigration(this.ref);

  final WidgetRef ref;

  NotionTemplateRetirement get _retirement =>
      NotionTemplateRetirement(ref.read(notionClientProvider));

  Future<void> start(BuildContext context) async {
    final NotionMapping? before = ref.read(notionMappingProvider).value;
    final NavigatorState navigator = Navigator.of(context);

    if (!await _explain(context)) return;
    if (!context.mounted) return;

    await navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'notion_connect'),
        builder: (BuildContext context) =>
            const NotionConnectScreen(retakeTemplate: true),
      ),
    );

    final NotionMapping? after = ref.read(notionMappingProvider).value;
    if (after == null || after.databaseId == before?.databaseId) return;

    // Every mark still points at a page in the database we just left, so the
    // links have to go before anything is written to the new one.
    final SyncRunResult? run =
        await ref.read(notionSyncStatusProvider.notifier).resyncEverything();
    if (!context.mounted) return;

    // Nothing is offered when the rewrite did not land: the old database is
    // the only copy of those rows until the new one is filled.
    if (run?.outcome != SyncRunOutcome.synced || before == null) {
      if (run?.outcome != SyncRunOutcome.synced) _say(context, _rewriteFailed);
      return;
    }

    await _settleOldDatabase(context, before);
    if (!context.mounted) return;

    // After the old database is dealt with, not before: that decision is the
    // one the user is waiting on, and the new template's gaps keep.
    if (notionMappingHasGaps(ref)) {
      await Navigator.of(context).push(notionMappingGapsRoute());
    }
  }

  Future<void> _settleOldDatabase(
    BuildContext context,
    NotionMapping before,
  ) async {
    final NotionConnectionStore store =
        ref.read(notionConnectionStoreProvider);
    // Resolved before the prompt, because it decides what the prompt can
    // honestly say is going: the page, or only the one table inside it.
    final String? page = await _retirement.pageOf(
      databaseId: before.databaseId,
      knownPageId: before.templatePageId,
    );
    if (!context.mounted) return;

    final _OldDatabase? choice =
        await _askAboutOld(context, before.title, whole: page != null);
    if (choice == null || choice == _OldDatabase.keep) {
      // Remembered so the offer outlives the moment it was made: Settings
      // keeps a way back until it is dealt with.
      await store.writeRetired(before.databaseId, before.title, pageId: page);
      ref.invalidate(retiredNotionDatabaseProvider);
      return;
    }

    if (choice == _OldDatabase.rename) {
      final NotionRename renamed = await _retirement.rename(
        databaseId: before.databaseId,
        databaseTitle: before.title,
        pageId: page,
      );
      // Stored from what the rename settled on rather than rebuilt here: the
      // page's name is not the table's, so the two would not agree.
      await store.writeRetired(
        before.databaseId,
        renamed.result.ok ? renamed.title : before.title,
        pageId: page,
      );
      ref.invalidate(retiredNotionDatabaseProvider);
      if (!context.mounted) return;
      _say(
        context,
        renamed.result.ok
            ? 'Renamed to "${renamed.title}".'
            : _changeFailed,
      );
      return;
    }

    final NotionResult result = await _retirement.trash(
      databaseId: before.databaseId,
      pageId: page,
      coursesDatabaseId: before.courses?.databaseId,
    );
    if (result.ok) {
      await store.clearRetired();
      ref.invalidate(retiredNotionDatabaseProvider);
    }
    if (!context.mounted) return;
    _say(
      context,
      result.ok ? 'Moved to the trash in Notion.' : _changeFailed,
    );
  }

  static const String _changeFailed =
      'Could not change the old database. It is still in Notion and can be '
      'renamed or deleted there.';

  static const String _rewriteFailed =
      'The new database is connected, but writing your marks into it did not '
      'finish. Use Sync now, then come back — the old database is untouched.';

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _explain(BuildContext context) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Take the latest template'),
        content: const Text(
          'Notion will add a new database to your workspace, and every mark '
          'is written into it. Your current one is left exactly as it is, and '
          'you choose what happens to it afterwards.',
          style: TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  /// Retires the database a migration left behind, from Settings rather than
  /// from the prompt that ran at the time.
  Future<void> trashRetired(
    BuildContext context,
    RetiredNotionDatabase retired,
  ) async {
    final String? page = retired.pageId;
    if (!await _confirmTrash(context, retired.title, whole: page != null)) {
      return;
    }

    final NotionResult result = await _retirement.trash(
      databaseId: retired.id,
      pageId: page,
    );
    // Already gone is the outcome that was asked for, so the row goes too.
    if (result.ok || result.message == 'object_not_found') {
      await ref.read(notionConnectionStoreProvider).clearRetired();
      ref.invalidate(retiredNotionDatabaseProvider);
    }
    if (!context.mounted) return;
    _say(
      context,
      result.ok
          ? 'Moved to the trash in Notion.'
          : 'Could not move it. It can be deleted in Notion instead.',
    );
  }

  Future<bool> _confirmTrash(
    BuildContext context,
    String title, {
    required bool whole,
  }) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Move it to trash?'),
        content: Text(
          whole
              ? 'The whole page $title came in goes to the trash in Notion — '
                  'its Courses table and every row with it. They can be '
                  'restored for thirty days. Nothing on this device changes.'
              : '$title and every row in it go to the trash in Notion, where '
                  'they can be restored for thirty days. Nothing on this '
                  'device changes.',
          style: const TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move to trash'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  Future<_OldDatabase?> _askAboutOld(
    BuildContext context,
    String title, {
    required bool whole,
  }) {
    return showDialog<_OldDatabase>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('And the old database?'),
        content: Text(
          <String>[
            'Your marks are now in the new database. "$title" is still in '
                'your workspace with a copy of all of them.',
            if (whole)
              'It came in a page of its own, so renaming or trashing it takes '
                  'that page and its Courses table with it.',
          ].join('\n\n'),
          style: const TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(_OldDatabase.keep),
            child: const Text('Leave it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_OldDatabase.rename),
            child: const Text('Rename it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_OldDatabase.trash),
            child: const Text('Move to trash'),
          ),
        ],
      ),
    );
  }
}
