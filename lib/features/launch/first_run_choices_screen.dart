import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_theme.dart';
import '../../core/endpoints.dart';
import '../../core/report_error.dart';
import '../../data/settings/app_settings.dart';
import '../../state/privacy_providers.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// The two questions asked before anything else: the age, then, for an adult,
/// whether usage statistics and crash reports may be sent.
///
/// Before the launch sequence rather than after it, because the welcome screen
/// it ends on offers an account, which is exactly what the age answer decides.
/// An install updating into this version is asked once too: its earlier
/// collection was never agreed to.
class FirstRunChoicesScreen extends ConsumerStatefulWidget {
  const FirstRunChoicesScreen({super.key, required this.settings});

  final AppSettings settings;

  static const String ageQuestion = 'Are you 18 or older?';
  static const String choicesTitle = 'Your choices';
  static const String usageTitle = 'Share usage statistics';
  static const String usageLine =
      'Which screens are opened and which features are used, never what you '
      'enter.';
  static const String crashesTitle = 'Send crash reports';
  static const String crashesLine =
      'The kind of error and where it happened, never what you enter.';

  @override
  ConsumerState<FirstRunChoicesScreen> createState() =>
      _FirstRunChoicesScreenState();
}

class _FirstRunChoicesScreenState extends ConsumerState<FirstRunChoicesScreen> {
  bool? _usage;
  bool? _crashes;
  bool _saving = false;

  /// Settings drive which step shows, so a saved age answer moves this on
  /// without a step counter of its own.
  Future<void> _run(Future<void> Function() write) async {
    setState(() => _saving = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await write();
    } catch (error, stack) {
      reportError(error, stack, where: 'first-run choices');
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save that. Try again.')),
      );
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? widget.settings;
    return settings.adult == null ? _age() : _choices();
  }

  Widget _age() {
    return GradientScaffold(
      headerGap: 22,
      header: const _Header(
        icon: Icons.cake_outlined,
        title: FirstRunChoicesScreen.ageQuestion,
        caption: 'Under 18, Zeolite keeps everything on this device: no '
            'account, no Notion, no AI check, and nothing measured. You can '
            'change this in Settings.',
      ),
      bottom: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              identifier: 'age_no',
              child: OutlinedButton(
                onPressed: _saving
                    ? null
                    : () => _run(
                        () => ref.read(privacyChoicesProvider).setAdult(false)),
                child: const Text('No'),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              identifier: 'age_yes',
              child: FilledButton(
                onPressed: _saving
                    ? null
                    : () => _run(
                        () => ref.read(privacyChoicesProvider).setAdult(true)),
                child: const Text('Yes'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choices() {
    final bool answered = _usage != null && _crashes != null;
    return GradientScaffold(
      headerGap: 22,
      header: const _Header(
        icon: Icons.tune_rounded,
        title: FirstRunChoicesScreen.choicesTitle,
        caption: 'Neither is on until you say yes. You can change both in '
            'Settings.',
      ),
      bottom: Semantics(
        identifier: 'choices_continue',
        child: FilledButton(
          onPressed: !answered || _saving
              ? null
              : () => _run(() => ref
                  .read(privacyChoicesProvider)
                  .setCollection(usage: _usage!, crashes: _crashes!)),
          child: const Text('Continue'),
        ),
      ),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          sliver: SliverList.list(
            children: <Widget>[
              _Choice(
                title: FirstRunChoicesScreen.usageTitle,
                line: FirstRunChoicesScreen.usageLine,
                value: _usage,
                onChanged: (bool v) => setState(() => _usage = v),
              ),
              const SizedBox(height: AppSpacing.md),
              _Choice(
                title: FirstRunChoicesScreen.crashesTitle,
                line: FirstRunChoicesScreen.crashesLine,
                value: _crashes,
                onChanged: (bool v) => setState(() => _crashes = v),
              ),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => launchUrl(
                    Endpoints.privacy,
                    mode: LaunchMode.inAppBrowserView,
                  ),
                  child: const Text('Read the Privacy Policy'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.icon,
    required this.title,
    required this.caption,
  });

  final IconData icon;
  final String title;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 18),
          Semantics(header: true, child: HeaderTitle(title)),
          const SizedBox(height: 8),
          HeaderCaption(caption, emphasis: 0.8),
        ],
      ),
    );
  }
}

/// A yes/no with neither side chosen until it is tapped.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.title,
    required this.line,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String line;
  final bool? value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: AppType.bodyMedium,
              height: 1.15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            line,
            style: TextStyle(
              fontSize: AppType.captionLarge,
              height: 1.35,
              color: context.palette.textTertiary,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            selected: <bool>{if (value != null) value!},
            onSelectionChanged: (Set<bool> picked) {
              // Tapping the chosen side again would empty the set; an answer
              // once given stays given.
              if (picked.isNotEmpty) onChanged(picked.single);
            },
            // Plain labels: a Semantics wrapper here splits the text into a
            // node of its own and leaves the segment's button unnamed.
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: false, label: Text('No')),
              ButtonSegment<bool>(value: true, label: Text('Yes')),
            ],
          ),
        ],
      ),
    );
  }
}
