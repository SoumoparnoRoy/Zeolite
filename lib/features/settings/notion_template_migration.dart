import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../services/notion/notion_client.dart';
import '../../services/notion/notion_connection_store.dart';
import '../../services/notion/notion_template_retirement.dart';
import '../../services/sync/sync_coordinator.dart';
import '../../state/notion_providers.dart';
import '../../state/providers.dart';
import '../../state/notion_sync_providers.dart';
import '../../widgets/common.dart';
import 'notion_connect_screen.dart';
import 'notion_mapping_gaps.dart';

/// What the user chose. Dismissing the prompt defers it, so there is no
/// button for that — Settings keeps the offer open either way.
enum _OldDatabase { rename, trash }

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

    // Before the rewrite rather than after it: the rewrite is what consumes
    // the mapping, and a column left unset is only filled in by paying for the
    // whole write again. Backing out is an answer too, and syncs as it stands.
    if (notionMappingHasGaps(ref)) {
      await navigator.push(notionMappingGapsRoute());
      if (!context.mounted) return;
    }

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
    if (choice == null) {
      // Remembered so the offer outlives the moment it was made: Settings
      // keeps a way back until it is dealt with.
      await store.writeRetired(before.databaseId, before.title, pageId: page);
      ref.invalidate(retiredNotionDatabasesProvider);
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
      ref.invalidate(retiredNotionDatabasesProvider);
      if (!context.mounted) return;
      _say(
        context,
        renamed.result.ok
            ? 'Renamed to "${renamed.title}"'
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
      // Only this one: an offer still open for a different page is not ours
      // to answer here.
      await store.removeRetired(before.databaseId);
      ref.invalidate(retiredNotionDatabasesProvider);
    }
    if (!context.mounted) return;
    _say(
      context,
      result.ok ? 'Moved to the trash in Notion' : _changeFailed,
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

  /// Retires the databases a migration left behind, from Settings rather than
  /// from the prompt that ran at the time.
  ///
  /// Several can be waiting: dismissing the prompt defers it, and taking the
  /// template again leaves another behind.
  Future<void> trashRetired(
    BuildContext context,
    List<RetiredNotionDatabase> retired,
  ) async {
    if (retired.isEmpty) return;

    // One is the ordinary case, and a sheet holding a single checkbox is
    // ceremony around a decision already made by tapping the row.
    final List<RetiredNotionDatabase> chosen = retired.length == 1
        ? retired
        : await _pickOldDatabases(context, retired) ??
            const <RetiredNotionDatabase>[];
    if (chosen.isEmpty || !context.mounted) return;

    // Resolved, not trusted: a record written before the page could be found
    // carries no id, and this is the last chance to retire the whole thing.
    final Map<RetiredNotionDatabase, String?> pages =
        <RetiredNotionDatabase, String?>{
      for (final RetiredNotionDatabase old in chosen)
        old: await _retirement.pageOf(
          databaseId: old.id,
          knownPageId: old.pageId,
        ),
    };
    if (!context.mounted) return;

    final bool go = await _confirmTrash(
      context,
      chosen.length == 1 ? chosen.single.title : null,
      // Whenever any of them came in a page, that is the sentence which has
      // to be read: it is the one saying the Courses table goes too.
      whole: pages.values.any((String? page) => page != null),
      count: chosen.length,
    );
    if (!go || !context.mounted) return;

    // Sequentially, and through a failure rather than stopping at it: the
    // alternative leaves an arbitrary subset done with no way to tell which.
    int moved = 0;
    for (final MapEntry<RetiredNotionDatabase, String?> old in pages.entries) {
      final NotionResult result = await _retirement.trash(
        databaseId: old.key.id,
        pageId: old.value,
      );
      // Already gone is the outcome that was asked for, so the row goes too.
      if (result.ok || result.message == 'object_not_found') {
        moved++;
        await ref
            .read(notionConnectionStoreProvider)
            .removeRetired(old.key.id);
      }
    }
    ref.invalidate(retiredNotionDatabasesProvider);
    if (!context.mounted) return;
    _say(context, notionTrashOutcome(moved: moved, of: chosen.length));
  }

  Future<List<RetiredNotionDatabase>?> _pickOldDatabases(
    BuildContext context,
    List<RetiredNotionDatabase> retired,
  ) {
    return showAppSheet<List<RetiredNotionDatabase>>(
      context: context,
      title: 'Which ones?',
      child: _OldDatabasePicker(retired: retired),
    );
  }

  Future<bool> _confirmTrash(
    BuildContext context,
    String? title, {
    required bool whole,
    required int count,
  }) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: Text(count == 1 ? 'Move it to trash?' : 'Move them to trash?'),
        content: Text(
          // Unnamed wherever a page is involved: after a rename the stored
          // title is the page's own, and "the whole page X came in" then
          // reads as X inside itself.
          switch ((whole, count)) {
            (true, 1) =>
              'The whole page this came in goes to the trash in Notion — '
                  'its Courses table and every row with it. They can be '
                  'restored for thirty days. Nothing on this device changes.',
            (true, _) =>
              'The whole page each of these came in goes to the trash in '
                  'Notion — the Courses table and every row with it. They '
                  'can be restored for thirty days. Nothing on this device '
                  'changes.',
            (false, 1) =>
              '$title and every row in it go to the trash in Notion, where '
                  'they can be restored for thirty days. Nothing on this '
                  'device changes.',
            (false, _) =>
              'They go to the trash in Notion with every row in them, where '
                  'they can be restored for thirty days. Nothing on this '
                  'device changes.',
          },
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

/// What a batch of retirements did.
///
/// Each database is its own call, so one the integration can no longer reach
/// says nothing about the rest. Only the all-succeeded case can be reached on
/// a device, which is why the strings are asserted in a test.
String notionTrashOutcome({required int moved, required int of}) {
  if (moved == of) {
    return of == 1
        ? 'Moved to the trash in Notion'
        : 'Moved $of to the trash in Notion';
  }
  if (moved == 0) {
    return of == 1
        ? 'Could not move it. It can be deleted in Notion instead.'
        : 'Could not move them. They can be deleted in Notion instead.';
  }
  final int failed = of - moved;
  return 'Moved $moved. Could not move $failed — '
      '${failed == 1 ? 'it' : 'they'} can be deleted in Notion instead.';
}

/// Picks which of the old databases go, when more than one is waiting.
class _OldDatabasePicker extends ConsumerStatefulWidget {
  const _OldDatabasePicker({required this.retired});

  final List<RetiredNotionDatabase> retired;

  @override
  ConsumerState<_OldDatabasePicker> createState() => _OldDatabasePickerState();
}

class _OldDatabasePickerState extends ConsumerState<_OldDatabasePicker> {
  /// Nothing ticked to begin with. These hold the user's rows, so the batch
  /// has to be assembled deliberately rather than opted out of.
  final Set<String> _chosen = <String>{};

  /// Two retakes in one sitting are minutes apart, so the time earns its
  /// place here even though the date carries most cases.
  String? _leftBehind(RetiredNotionDatabase old) {
    final DateTime? at = old.retiredAt;
    if (at == null) return null;
    final bool use24Hour =
        ref.watch(settingsProvider).value?.use24HourTime ?? false;
    return 'Left behind ${Dates.formatFull(at)}, '
        '${Clock.format(at.hour * 60 + at.minute, use24Hour: use24Hour)}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final RetiredNotionDatabase old in widget.retired) ...<Widget>[
          SurfaceCard(
            onTap: () => setState(() {
              if (!_chosen.remove(old.id)) _chosen.add(old.id);
            }),
            child: Row(
              children: <Widget>[
                Checkbox.adaptive(
                  value: _chosen.contains(old.id),
                  onChanged: (_) => setState(() {
                    if (!_chosen.remove(old.id)) _chosen.add(old.id);
                  }),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        old.title,
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_leftBehind(old) case final String label)
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: context.palette.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.sm),
        FilledButton(
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.of(context).pop(<RetiredNotionDatabase>[
                    for (final RetiredNotionDatabase old in widget.retired)
                      if (_chosen.contains(old.id)) old,
                  ]),
          child: const Text('Move to trash'),
        ),
      ],
    );
  }
}
