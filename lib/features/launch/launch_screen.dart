import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings/app_settings.dart';
import '../../state/auth_providers.dart';
import '../../state/providers.dart';
import 'joining_screen.dart';
import 'launch_geometry.dart';
import 'launch_painter.dart';
import 'welcome_auth_screen.dart';
import 'welcome_screen.dart';

/// The launch sequence, and on a first run the welcome screen it opens into.
///
/// Not a delay: it plays while Firebase restores the session, and whichever
/// finishes last is the gate, so the timeline is only a floor.
class LaunchScreen extends ConsumerStatefulWidget {
  const LaunchScreen({
    super.key,
    required this.settings,
    required this.onFinished,
  });

  final AppSettings settings;

  /// Called once the app should take over, and on a first run not before the
  /// welcome screen has had its answer.
  final VoidCallback onFinished;

  @override
  ConsumerState<LaunchScreen> createState() => _LaunchScreenState();
}

class _LaunchScreenState extends ConsumerState<LaunchScreen>
    with SingleTickerProviderStateMixin {
  late final bool _short =
      widget.settings.launchAnimation == LaunchAnimation.short;

  /// Read once: saving `welcomeShown` rebuilds this widget mid-sequence, and
  /// re-deciding would restart it as the other flow.
  late final LaunchLanding _landing = widget.settings.welcomeShown
      ? LaunchLanding.today
      : LaunchLanding.welcome;

  late final double _mainEnd =
      _short ? LaunchTiming.shortEnd : LaunchTiming.mainEnd;

  late final double _total = _mainEnd +
      (_landing == LaunchLanding.welcome
          ? LaunchTiming.welcomeHandoff
          : LaunchTiming.todayHandoff);

  /// Milliseconds since the sequence began, and deliberately unbounded: the
  /// crystal keeps turning under the welcome screen rather than stopping dead
  /// on the last frame.
  late final AnimationController _clock =
      AnimationController.unbounded(vsync: this);

  /// Accessibility › Remove animations, or an animator duration scale of zero.
  late final bool _stillness = WidgetsBinding
      .instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  bool _played = false;
  bool _handedOver = false;

  /// Set once a sign-in has landed: what follows is the account's answer to
  /// the first-run questions, not this device's.
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    // Left alone a controller honours that setting by running at a twentieth
    // of its duration, which is a scramble rather than a still.
    if (_stillness) {
      _clock.value = _total;
      _played = true;
      return;
    }
    _clock
      ..addListener(_watchForTheEnd)
      ..animateWith(_RealTime());
  }

  void _watchForTheEnd() {
    if (_played || _clock.value < _total) return;
    // The app is what moves next, so there is nothing left to turn.
    if (_landing == LaunchLanding.today) _clock.stop();
    setState(() => _played = true);
  }

  @override
  void dispose() {
    _clock.removeListener(_watchForTheEnd);
    _clock.dispose();
    super.dispose();
  }

  Future<void> _choose(WelcomeChoice choice) async {
    bool signedIn = false;
    if (choice != WelcomeChoice.continueWithout) {
      signedIn = await Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              settings: const RouteSettings(name: 'welcome_auth'),
              builder: (BuildContext context) => WelcomeAuthScreen(
                creating: choice == WelcomeChoice.create,
              ),
            ),
          ) ??
          false;
      // Backing out leaves the choice open rather than deciding it for them.
      if (!signedIn || !mounted) return;
    }

    // Read again rather than from `widget`: signing in starts a sync, and the
    // settings it pulls are newer than the ones this screen was built with.
    final AppSettings current =
        ref.read(settingsProvider).value ?? widget.settings;
    await ref
        .read(settingsProvider.notifier)
        .save(current.copyWith(welcomeShown: true));
    if (!mounted) return;
    if (signedIn) {
      setState(() => _joining = true);
      return;
    }
    widget.onFinished();
  }

  void _finishWhenReady(AsyncValue<User?> auth) {
    if (_handedOver || !_played || auth.isLoading) return;
    _handedOver = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFinished();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<User?> auth = ref.watch(signedInUserProvider);
    if (_landing == LaunchLanding.today) _finishWhenReady(auth);

    final LaunchColors colors = LaunchColors.of(widget.settings.accentColour);
    if (_joining) {
      return JoiningScreen(colors: colors, onDone: widget.onFinished);
    }

    final MediaQueryData mq = MediaQuery.of(context);
    // The viewer's own scaling only; the app's size ramp is for reading.
    final double scale = mq.textScaler.scale(10) / 10;

    return Scaffold(
      backgroundColor: colors.canvas,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          final WelcomeMetrics metrics = WelcomeMetrics(
            size: size,
            scale: scale,
            frame: WelcomeMetrics.frameFor(size),
            bottomInset: mq.padding.bottom,
          );

          return AnimatedBuilder(
            animation: _clock,
            builder: (BuildContext context, Widget? child) {
              final double progress = seg(_clock.value, _mainEnd, _total);
              // Expanded, and never given an unpositioned child: a Stack
              // sizes itself to those, so one shrunken child collapses it and
              // the painter is handed a zero canvas.
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: LaunchPainter(
                          clock: _clock,
                          short: _short,
                          landing: _landing,
                          colors: colors,
                          metrics: metrics,
                          textScale: scale,
                        ),
                        size: size,
                      ),
                    ),
                  ),
                  if (_landing == LaunchLanding.welcome) ...<Widget>[
                    // The heading is painted, so this is what a reader finds.
                    Positioned(
                      left: 0,
                      right: 0,
                      top: metrics.headingBaseline - metrics.headingSize,
                      height: metrics.headingSize * 1.6,
                      child: Semantics(
                        header: true,
                        label: WelcomeCopy.heading,
                        child: const SizedBox.expand(),
                      ),
                    ),
                    WelcomeCopy(
                      metrics: metrics,
                      colors: colors,
                      progress: progress,
                      onChoice: _choose,
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Wall-clock milliseconds, never done.
class _RealTime extends Simulation {
  @override
  double x(double time) => time * 1000;

  @override
  double dx(double time) => 1000;

  @override
  bool isDone(double time) => false;
}
