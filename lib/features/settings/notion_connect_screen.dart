import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_theme.dart';
import '../../domain/sync/sync_target.dart';
import '../../services/notion/notion_auth_client.dart';
import '../../services/notion/pkce.dart';
import '../../state/notion_providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import 'notion_mapping_screen.dart';

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

enum _Stage { idle, waiting, claiming }

class _NotionConnectScreenState extends ConsumerState<NotionConnectScreen> {
  final TextEditingController _code = TextEditingController();
  final AppLinks _links = AppLinks();
  StreamSubscription<Uri>? _sub;

  /// Read back from the store on open, so an attempt survives leaving this
  /// screen while the browser is in front.
  String? _verifier;
  _Stage _stage = _Stage.idle;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Wakes a spun-down host while the user is still reading this screen.
    // Nothing waits on it and a failure changes nothing.
    unawaited(ref.read(notionAuthClientProvider).health());
    _sub = _links.uriLinkStream.listen(_onLink);
    unawaited(_resume());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _code.dispose();
    super.dispose();
  }

  /// Picks up an attempt already in the browser. Anything older than the
  /// service keeps its session for reads back as nothing.
  Future<void> _resume() async {
    final String? pending =
        await ref.read(notionConnectionStoreProvider).readPending();
    if (!mounted || pending == null) return;
    setState(() {
      _verifier = pending;
      _stage = _Stage.waiting;
    });
  }

  void _onLink(Uri uri) {
    if (uri.scheme != 'zeolite' || uri.host != 'notion') return;
    final String? session = uri.queryParameters['session'];
    if (session != null && session.isNotEmpty) _claim(session: session);
  }

  Future<void> _start() async {
    final PkcePair pair = PkcePair.generate();
    final Uri uri = ref.read(notionAuthClientProvider).startUri(pair.challenge);
    // A browser tab, never `externalApplication`: the Notion app claims
    // api.notion.com and, handed the authorize URL, swallows the client id and
    // state and shows its own login screen. RFC 8252 says the same thing.
    final bool opened =
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    // Written before the browser can come back, not after.
    if (opened) {
      await ref
          .read(notionConnectionStoreProvider)
          .writePending(pair.verifier);
    }
    if (!mounted) return;
    setState(() {
      _verifier = opened ? pair.verifier : null;
      _stage = opened ? _Stage.waiting : _Stage.idle;
      _error = opened ? null : 'No browser could be opened to sign in with.';
    });
  }

  Future<void> _claim({String? session, String? pairingCode}) async {
    final String? verifier = _verifier;
    if (verifier == null || _stage == _Stage.claiming) return;

    setState(() {
      _stage = _Stage.claiming;
      _error = null;
    });

    final NotionAuthResult result = await ref
        .read(notionAuthClientProvider)
        .claim(
          session: session,
          pairingCode: pairingCode,
          verifier: verifier,
        );

    if (!mounted) return;
    if (result.ok) {
      await ref.read(notionConnectionStoreProvider).clearPending();
      await ref
          .read(notionConnectionProvider.notifier)
          .connect(result.tokens!);
      if (!mounted) return;
      await _settleMapping(result.tokens!);
      return;
    }
    setState(() {
      _stage = _Stage.waiting;
      _error = _messageFor(result.failure);
    });
  }

  /// The template is the schema this app authored, so mapping it is a fact
  /// rather than a guess. Anyone else's database is never mapped unseen.
  Future<void> _settleMapping(NotionTokens tokens) async {
    final NavigatorState navigator = Navigator.of(context);
    final String? template = tokens.duplicatedTemplateId;

    if (template != null && template.isNotEmpty) {
      final bool mapped = await ref
          .read(notionMappingProvider.notifier)
          .adoptTemplate(template);
      if (!mounted) return;
      if (mapped) {
        navigator.pop();
        return;
      }
    }

    // Replaced, so coming back lands in Settings and not on a connect screen
    // for a connection already made.
    unawaited(
      navigator.pushReplacement(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'notion_mapping'),
          builder: (BuildContext context) => const NotionMappingScreen(),
        ),
      ),
    );
  }

  String _messageFor(SyncFailure? failure) {
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

  @override
  Widget build(BuildContext context) {
    return PushScaffold(
      title: 'Connect Notion',
      subtitle: 'Sync your attendance into your own workspace',
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _body(context),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _body(BuildContext context) {
    final NotionTokens? connected = ref.watch(notionConnectionProvider).value;
    if (connected != null && !widget.retakeTemplate) {
      return _connected(context, connected);
    }

    final bool busy = _stage == _Stage.claiming;
    return <Widget>[
      SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.retakeTemplate
                  ? 'You will go back to Notion and take a fresh copy of the '
                      'template. Your current database is left exactly as it '
                      'is until the new one is filled.'
                  : 'You will sign in to Notion in your browser and choose '
                      'which pages Zeolite may write to. Your attendance '
                      'stays on this device as well.',
              style: TextStyle(color: context.palette.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'The first connection can take up to a minute while the service '
              'wakes up.',
              style: TextStyle(
                fontSize: 12,
                color: context.palette.textTertiary,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      FilledButton(
        onPressed: busy ? null : _start,
        child: Text(
          switch ((_stage, widget.retakeTemplate)) {
            (_Stage.idle, true) => 'Take the latest template',
            (_Stage.idle, false) => 'Connect Notion',
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
        enabled: !busy && _verifier != null,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(hintText: 'Eight characters'),
        onSubmitted: (String value) => _claim(pairingCode: value),
      ),
      const SizedBox(height: AppSpacing.sm),
      OutlinedButton(
        onPressed: busy || _verifier == null
            ? null
            : () => _claim(pairingCode: _code.text),
        child: const Text('Finish connecting'),
      ),
      if (_verifier == null) ...<Widget>[
        const SizedBox(height: AppSpacing.sm),
        Text(
          'The code only works with an attempt you have started, so tap '
          '${widget.retakeTemplate ? 'Take the template' : 'Connect Notion'} '
          'first.',
          style: TextStyle(
            fontSize: 12,
            color: context.palette.textTertiary,
          ),
        ),
      ],
      // An attempt still outstanding while this screen is visible *is* the
      // failure signature — a redirect that worked would have popped it. The
      // cause is Notion's app swallowing the Google sign-in redirect.
      if (_verifier != null && !busy) ...<Widget>[
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
      if (busy) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        const Center(child: CircularProgressIndicator()),
      ],
      if (_error != null) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        Text(
          _error!,
          style: TextStyle(color: context.palette.absent),
        ),
      ],
    ];
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
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Your attendance is synced to this workspace. It stays on this '
              'device too.',
              style: TextStyle(color: context.palette.textSecondary),
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      OutlinedButton(
        onPressed: () async {
          await ref.read(notionConnectionProvider.notifier).disconnect();
          if (context.mounted) Navigator.of(context).pop();
        },
        child: const Text('Disconnect'),
      ),
    ];
  }
}
