import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../services/notion/notion_auth_client.dart';
import '../../state/notion_pairing.dart';
import '../../state/notion_providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import 'notion_mapping_screen.dart';
import 'notion_mapping_gaps.dart';

/// Authorising Notion, both ways it can come back.
///
/// The redirect to `zeolite://notion` is the quick path, and the typed pairing
/// code is shown from the start rather than after a timeout — a custom-scheme
/// return is dropped by enough browsers that an escape hatch which only
/// appears once something has already gone wrong is the wrong shape.
class NotionConnectScreen extends ConsumerStatefulWidget {
  const NotionConnectScreen({super.key, this.retakeTemplate = false});

  /// Runs consent again on a workspace already connected, which is the only
  /// way Notion hands over a copy of a newer template. Without it this screen
  /// offers nothing but Disconnect, and taking a new template would mean
  /// tearing down a working connection first.
  final bool retakeTemplate;

  @override
  ConsumerState<NotionConnectScreen> createState() =>
      _NotionConnectScreenState();
}

class _NotionConnectScreenState extends ConsumerState<NotionConnectScreen> {
  final TextEditingController _code = TextEditingController();
  final AppLinks _links = AppLinks();
  StreamSubscription<Uri>? _sub;

  NotionPairingController get _pairing =>
      ref.read(notionPairingProvider.notifier);

  @override
  void initState() {
    super.initState();
    _sub = _links.uriLinkStream.listen(_onLink);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _code.dispose();
    super.dispose();
  }

  void _onLink(Uri uri) {
    if (uri.scheme != 'zeolite' || uri.host != 'notion') return;
    final String? session = uri.queryParameters['session'];
    if (session != null && session.isNotEmpty) {
      unawaited(_claim(session: session));
    }
  }

  Future<void> _claim({String? session, String? pairingCode}) async {
    final NavigatorState navigator = Navigator.of(context);
    final NotionClaimOutcome? outcome =
        await _pairing.claim(session: session, pairingCode: pairingCode);
    if (!mounted) return;
    switch (outcome) {
      case null || NotionClaimOutcome.refused:
        return;
      case NotionClaimOutcome.adopted:
        // Replaced rather than pushed, so Back from either destination lands
        // in Settings and not on a connection already made. A retake is
        // sequenced by the migration instead, which has more to ask after.
        if (!widget.retakeTemplate && notionMappingHasGaps(ref)) {
          unawaited(navigator.pushReplacement(notionMappingGapsRoute()));
        } else {
          navigator.pop();
        }
      case NotionClaimOutcome.needsMapping:
        // Replaced, so coming back lands in Settings and not on a connect
        // screen for a connection already made.
        unawaited(
          navigator.pushReplacement(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'notion_mapping'),
              builder: (BuildContext context) => const NotionMappingScreen(),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final NotionPairing pairing = ref.watch(notionPairingProvider);
    return PushScaffold(
      title: 'Connect Notion',
      subtitle: 'Sync your attendance into your own workspace',
      slivers: <Widget>[
        // The tokens are stored before the template is adopted, so the
        // connected card would otherwise stand here offering Disconnect over a
        // claim still running — and then vanish when the mapping replaces it.
        if (pairing.stage == NotionPairingStage.claiming)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: _finishing(context)),
          )
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _body(context, pairing),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _body(BuildContext context, NotionPairing pairing) {
    final NotionTokens? connected = ref.watch(notionConnectionProvider).value;
    if (connected != null && !widget.retakeTemplate) {
      return _connected(context, connected);
    }

    return <Widget>[
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.retakeTemplate
                  ? 'You will go back to Notion and take a fresh copy of the '
                      'template. Your current table is left exactly as it '
                      'is until the new one is filled.'
                  : 'You will sign in to Notion in your browser and choose '
                      'which pages Zeolite may write to. Your attendance '
                      'stays on this device as well.\n\n'
                      'Already have a Zeolite Attendance page? Pick the page '
                      'itself, not one table inside it — Notion hides the '
                      'Course link unless both tables come along. Search for '
                      'it by name; the picker only lists what you opened '
                      'recently.',
              style: TextStyle(color: context.palette.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'The first connection can take up to a minute while the service '
              'wakes up.',
              style: TextStyle(
                fontSize: AppType.bodySmall,
                color: context.palette.textTertiary,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      FilledButton(
        onPressed: _pairing.start,
        child: Text(
          switch ((pairing.stage, widget.retakeTemplate)) {
            (NotionPairingStage.idle, true) => 'Take the latest template',
            (NotionPairingStage.idle, false) => 'Connect Notion',
            _ => 'Open Notion again',
          },
        ),
      ),
      const SizedBox(height: AppSpacing.xl),
      Text(
        'Or type the code from the browser',
        style: TextStyle(color: context.palette.textSecondary),
      ),
      const SizedBox(height: AppSpacing.sm),
      TextField(
        controller: _code,
        enabled: pairing.verifier != null,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(hintText: 'Eight characters'),
        onSubmitted: (String value) => _claim(pairingCode: value),
      ),
      const SizedBox(height: AppSpacing.sm),
      OutlinedButton(
        onPressed: pairing.verifier == null
            ? null
            : () => _claim(pairingCode: _code.text),
        child: const Text('Finish connecting'),
      ),
      if (pairing.verifier == null) ...<Widget>[
        const SizedBox(height: AppSpacing.sm),
        Text(
          'The code only works with an attempt you have started, so tap '
          '${widget.retakeTemplate ? 'Take the template' : 'Connect Notion'} '
          'first.',
          style: TextStyle(
            fontSize: AppType.bodySmall,
            color: context.palette.textTertiary,
          ),
        ),
      ],
      // An attempt still outstanding while this screen is visible *is* the
      // failure signature — a redirect that worked would have popped it. The
      // cause is Notion's app swallowing the Google sign-in redirect.
      if (pairing.verifier != null) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Did not get back from Notion?',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                "If Notion's own app opened instead of the sign-in page, sign "
                'in to Notion in your browser using Email, then tap Open '
                'Notion again.',
                style: TextStyle(color: context.palette.textSecondary),
              ),
            ],
          ),
        ),
      ],
      if (pairing.error != null) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        Text(
          pairing.error!,
          style: TextStyle(color: context.palette.absent),
        ),
      ],
    ];
  }

  /// Claiming covers the template adoption as well, which is several Notion
  /// reads, and the screen leaves by itself at the end of it either way.
  Widget _finishing(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Finishing the connection. This screen moves on by itself when it '
            'is done.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.palette.textSecondary),
          ),
        ],
      ),
    );
  }

  /// The privacy policy promises disconnecting stops sync and leaves the app
  /// untouched, so it has to be reachable from the same place connecting is.
  List<Widget> _connected(BuildContext context, NotionTokens tokens) {
    return <Widget>[
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              tokens.workspaceName ?? 'Connected',
              style: const TextStyle(
                  fontSize: AppType.headlineMedium,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _mapped
                  ? 'Your attendance is synced to this workspace. It stays on '
                      'this device too.'
                  : 'Connected, but nothing is syncing yet: Zeolite still '
                      'needs to know which columns hold what.',
              style: TextStyle(color: context.palette.textSecondary),
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      // The only way back in: leaving the mapping half-finished used to strand
      // the connection here with nothing but Disconnect.
      OutlinedButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: 'notion_mapping'),
            builder: (BuildContext context) => const NotionMappingScreen(),
          ),
        ),
        child: Text(_mapped ? 'Change the table' : 'Finish setting up'),
      ),
      const SizedBox(height: AppSpacing.sm),
      OutlinedButton(
        onPressed: () async {
          await ref.read(notionConnectionProvider.notifier).disconnect();
          if (context.mounted) Navigator.of(context).pop();
        },
        child: const Text('Disconnect'),
      ),
    ];
  }

  /// A connection on its own writes nothing; the columns decide that.
  bool get _mapped =>
      ref.watch(notionMappingProvider).value?.isComplete ?? false;
}
