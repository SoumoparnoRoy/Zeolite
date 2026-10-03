import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/sync/sync_target.dart';
import '../services/notion/notion_auth_client.dart';
import '../services/notion/pkce.dart';
import 'notion_providers.dart';

enum NotionPairingStage { idle, waiting, claiming }

/// Where a connection attempt stands.
@immutable
class NotionPairing {
  const NotionPairing({
    this.stage = NotionPairingStage.idle,
    this.verifier,
    this.error,
  });

  final NotionPairingStage stage;

  /// Read back from the store on open, so an attempt survives leaving the
  /// screen while the browser is in front.
  final String? verifier;
  final String? error;
}

/// How a claim ended, which decides where the screen goes next.
enum NotionClaimOutcome {
  refused,

  /// Connected on the template this app authored, mapped without asking.
  adopted,

  /// Connected, but the columns still have to be chosen.
  needsMapping,
}

final notionPairingProvider =
    NotifierProvider.autoDispose<NotionPairingController, NotionPairing>(
  NotionPairingController.new,
);

/// Authorising Notion, both ways it can come back: the redirect, or the
/// pairing code typed from the browser.
class NotionPairingController extends Notifier<NotionPairing> {
  @override
  NotionPairing build() {
    // Wakes a spun-down host while the user is still reading the screen.
    // Nothing waits on it and a failure changes nothing.
    unawaited(ref.read(notionAuthClientProvider).health());
    scheduleMicrotask(() => unawaited(_resume()));
    return const NotionPairing();
  }

  /// Picks up an attempt already in the browser. Anything older than the
  /// service keeps its session for reads back as nothing.
  Future<void> _resume() async {
    final String? pending =
        await ref.read(notionConnectionStoreProvider).readPending();
    if (!ref.mounted || pending == null) return;
    state = NotionPairing(
      stage: NotionPairingStage.waiting,
      verifier: pending,
      error: state.error,
    );
  }

  Future<void> start() async {
    final PkcePair pair = PkcePair.generate();
    final Uri uri = ref.read(notionAuthClientProvider).startUri(pair.challenge);
    // A browser tab, never `externalApplication`: the Notion app claims
    // api.notion.com and, handed the authorize URL, swallows the client id and
    // state and shows its own login screen. RFC 8252 says the same thing.
    final bool opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    // Written before the browser can come back, not after.
    if (opened) {
      await ref.read(notionConnectionStoreProvider).writePending(pair.verifier);
    }
    if (!ref.mounted) return;
    state = opened
        ? NotionPairing(
            stage: NotionPairingStage.waiting,
            verifier: pair.verifier,
          )
        : const NotionPairing(
            error: 'No browser could be opened to sign in with.',
          );
  }

  /// Null when there is nothing to claim, or a claim is already running.
  Future<NotionClaimOutcome?> claim({
    String? session,
    String? pairingCode,
  }) async {
    final String? verifier = state.verifier;
    if (verifier == null || state.stage == NotionPairingStage.claiming) {
      return null;
    }
    state = NotionPairing(
      stage: NotionPairingStage.claiming,
      verifier: verifier,
    );

    final NotionAuthResult result =
        await ref.read(notionAuthClientProvider).claim(
              session: session,
              pairingCode: pairingCode,
              verifier: verifier,
            );
    if (!ref.mounted) return null;
    if (!result.ok) {
      state = NotionPairing(
        stage: NotionPairingStage.waiting,
        verifier: verifier,
        error: _messageFor(result.failure),
      );
      return NotionClaimOutcome.refused;
    }

    await ref.read(notionConnectionStoreProvider).clearPending();
    await ref.read(notionConnectionProvider.notifier).connect(result.tokens!);
    if (!ref.mounted) return null;

    // The template is the schema this app authored, so mapping it is a fact
    // rather than a guess. Anyone else's database is never mapped unseen.
    final String? template = result.tokens!.duplicatedTemplateId;
    if (template != null && template.isNotEmpty) {
      final bool mapped = await ref
          .read(notionMappingProvider.notifier)
          .adoptTemplate(template);
      if (!ref.mounted) return null;
      if (mapped) return NotionClaimOutcome.adopted;
    }
    return NotionClaimOutcome.needsMapping;
  }

  static String _messageFor(SyncFailure? failure) {
    switch (failure) {
      case SyncFailure.offline:
        return 'Could not reach the connection service. Check your network '
            'and try again.';
      case SyncFailure.rejected:
        return 'That code did not work, or the connection expired. Start '
            'again from Connect Notion.';
      case SyncFailure.rateLimited:
        return 'Too many attempts. Wait a minute, then try again.';
      default:
        return 'Something went wrong finishing the connection. Try again.';
    }
  }
}
