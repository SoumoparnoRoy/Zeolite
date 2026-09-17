import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../domain/notion_export.dart';
import '../../domain/sync/sync_plan.dart';
import '../../domain/sync/sync_status.dart';
import '../../domain/sync/sync_target.dart';
import '../../services/notion/notion_connection_store.dart';
import '../../services/notion/notion_database_reader.dart';
import '../../services/sync/sync_coordinator.dart';
import '../../state/auth_providers.dart';
import '../../state/notion_providers.dart';
import '../../state/notion_sync_providers.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../subjects/notion_import_screen.dart';

import 'account_screen.dart';
import 'notion_connect_screen.dart';
import 'notion_mapping_screen.dart';
import 'notion_review_screen.dart';
import 'notion_template_migration.dart';
import 'settings_rows.dart';
import 'sync_status_line.dart';

class AccountSection extends ConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Account'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              SettingsRow(
                icon: Icons.cloud_outlined,
                title: 'Backup and sync',
                value: ref.watch(signedInUserProvider).value?.email ??
                    'Not signed in — nothing is backed up',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(name: 'account'),
                    builder: (BuildContext context) => const AccountScreen(),
                  ),
                ),
              ),
              // Signing in is consent to have an account, not consent to
              // upload; nothing leaves the device until this is on.
              if (ref.watch(signedInUserProvider).value != null) ...[
                const Divider(indent: 58),
                SettingsRow(
                  icon: Icons.schedule_rounded,
                  title: 'Sync automatically',
                  value: 'About 15 seconds after you mark a class',
                  trailing: Switch(
                    value: settings.accountAutoSync,
                    onChanged: (bool on) => ref
                        .read(settingsProvider.notifier)
                        .save(settings.copyWith(accountAutoSync: on)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class NotionSection extends ConsumerWidget {
  const NotionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Notion'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              SettingsRow(
                icon: Icons.sync_alt_rounded,
                title: 'Notion sync',
                value:
                    ref.watch(notionConnectionProvider).value?.workspaceName ??
                        'Not connected',
                onTap: () {
                  // The connect screen wakes the host too, but not until
                  // it is built, so the push transition is spent idle.
                  unawaited(ref.read(notionAuthClientProvider).health());
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: 'notion_connect'),
                      builder: (BuildContext context) =>
                          const NotionConnectScreen(),
                    ),
                  );
                },
              ),
              // A mapping the app chose itself has to be visible.
              if (ref.watch(notionConnectionProvider).value != null)
                SettingsRow(
                  icon: Icons.table_chart_outlined,
                  title: 'Database',
                  value: ref.watch(notionMappingProvider).value?.title ??
                      'Not set up',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: 'notion_mapping'),
                      builder: (BuildContext context) =>
                          const NotionMappingScreen(),
                    ),
                  ),
                ),
              // A new schema only arrives by taking the template again.
              if (ref.watch(notionMappingProvider).value != null)
                SettingsRow(
                  icon: Icons.auto_awesome_motion_outlined,
                  title: 'Take the latest template',
                  value: 'Move to a new database and rewrite every row',
                  onTap: () => NotionTemplateMigration(ref).start(context),
                ),
              // Several wait whenever a template was retaken without
              // answering the prompt.
              if (ref.watch(retiredNotionDatabasesProvider).value
                  case final List<RetiredNotionDatabase> retired
                  when retired.isNotEmpty)
                SettingsRow(
                  icon: Icons.delete_outline_rounded,
                  title: 'Move an old database to trash',
                  value: retired.length == 1
                      ? retired.single.title
                      : '${retired.length} are waiting',
                  onTap: () => NotionTemplateMigration(ref)
                      .trashRetired(context, retired),
                ),
              // Sync's own pull drops these rows, so this is the way in.
              if (ref.watch(notionMappingProvider).value != null)
                SettingsRow(
                  icon: Icons.download_for_offline_outlined,
                  title: 'Import from your database',
                  value: 'Bring in classes already recorded in Notion',
                  onTap: () => _importFromNotion(context, ref),
                ),
              if (ref.watch(notionSyncTargetProvider) != null)
                SettingsRow(
                  icon: Icons.schedule_rounded,
                  title: 'Sync automatically',
                  value: 'About 15 seconds after you mark a class',
                  trailing: Switch(
                    value: settings.notionAutoSync,
                    onChanged: (bool on) => ref
                        .read(settingsProvider.notifier)
                        .save(settings.copyWith(notionAutoSync: on)),
                  ),
                ),
            ],
          ),
        ),
        // A failing sync has to be visible, or the app reads as working.
        if (ref.watch(notionSyncTargetProvider) != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          const _NotionSyncCard(),
        ],
      ],
    );
  }

  /// Reads the mapped database into the same preview the CSV goes through.
  Future<void> _importFromNotion(BuildContext context, WidgetRef ref) async {
    final NotionMapping? mapping = ref.read(notionMappingProvider).value;
    if (mapping == null) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => const AlertDialog(
        content: SizedBox(
          height: 64,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    ));

    final NotionReadResult result = await NotionDatabaseReader(
      client: ref.read(notionClientProvider),
      mapping: mapping,
    ).read();
    navigator.pop();

    final NotionSource? source = result.source;
    if (source == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(_notionReadFailure(result.failure)),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    // Only worth asking where there is something of ours to leave out.
    bool skipKeyed = false;
    if (source.hasKeyedRows) {
      if (!context.mounted) return;
      final bool? answer = await _askWhichRows(context);
      if (answer == null) return;
      skipKeyed = answer;
    }

    final NotionExport export = source.read(skipKeyed: skipKeyed);
    if (export.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(export.problems.isEmpty
              ? 'Nothing in that database could be read as a class.'
              : export.problems.first),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    await navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'notion_import'),
        builder: (BuildContext context) => NotionImportScreen(export: export),
      ),
    );
  }

  /// True to skip the app's own rows; null is a cancel.
  static Future<bool?> _askWhichRows(BuildContext context) => showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          backgroundColor: context.palette.surfaceHigh,
          title: const Text('Which rows?'),
          content: const Text(
            'Some rows in that database were written by this app. Bring them '
            'in too if you are setting this device up again, or leave them out '
            'if you only want what you typed into Notion yourself.',
            style: TextStyle(height: 1.4),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Only mine'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Everything'),
            ),
          ],
        ),
      );

  static String _notionReadFailure(SyncFailure? failure) => switch (failure) {
        SyncFailure.auth =>
          'Zeolite is not allowed to read your workspace any more. Disconnect '
              'Notion and connect it again.',
        SyncFailure.offline =>
          'Could not reach Notion. Check your network and try again.',
        SyncFailure.rateLimited => 'Notion is busy. Wait a moment and try '
            'again.',
        _ => 'Notion refused that request. Check the database is still shared '
            'with Zeolite.',
      };
}

/// A card rather than a row: a failure needs a sentence and a button.
class _NotionSyncCard extends ConsumerWidget {
  const _NotionSyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SyncStatus status = ref.watch(notionSyncStatusProvider);
    final SyncRunResult? last =
        ref.read(notionSyncStatusProvider.notifier).lastResult;
    final bool running = status.state == SyncState.running;
    final List<SyncPull> review =
        ref.read(notionSyncStatusProvider.notifier).review;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            syncStatusLine(
              status,
              last,
              storedLastSyncAt:
                  ref.watch(settingsProvider).value?.lastNotionSyncAt,
              authAdvice: 'Disconnect Notion and connect it again.',
            ),
            style: TextStyle(color: context.palette.textSecondary),
          ),
          // Saying only "synced" would let the two sides drift unremarked.
          if (review.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              onPressed: running
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          settings: const RouteSettings(name: 'notion_review'),
                          builder: (BuildContext context) =>
                              const NotionReviewScreen(),
                        ),
                      ),
              child: Text(
                'Review ${review.length} changed in Notion',
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            onPressed: running
                ? null
                : () => ref
                    .read(notionSyncStatusProvider.notifier)
                    .run(force: true),
            child: Text(status.failures > 0 ? 'Try again' : 'Sync now'),
          ),
          const SizedBox(height: AppSpacing.sm),
          // For when what the app writes has changed rather than what the
          // marks say — see `resyncEverything`.
          TextButton(
            onPressed: running
                ? null
                : () => ref
                    .read(notionSyncStatusProvider.notifier)
                    .resyncEverything(),
            child: const Text('Rewrite every row'),
          ),
        ],
      ),
    );
  }
}
