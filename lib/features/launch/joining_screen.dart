import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/sync/sync_status.dart';
import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import 'launch_painter.dart';

/// Held between signing in and the app opening, while the first sync says
/// whether the account already knows the term. That answer decides the next
/// screen: asking the first-run questions of an account that has answered
/// them puts the user's defaults on top of what was just pulled.
class JoiningScreen extends ConsumerStatefulWidget {
  const JoiningScreen({
    super.key,
    required this.colors,
    required this.onDone,
  });

  static const String heading = 'Getting your timetable';
  static const String caption = 'This only happens once.';

  /// Long enough for a slow connection, short enough that a target which
  /// never answers cannot strand anyone. Falling through only means being
  /// asked for the term.
  static const Duration wait = Duration(seconds: 10);

  final LaunchColors colors;

  final VoidCallback onDone;

  @override
  ConsumerState<JoiningScreen> createState() => _JoiningScreenState();
}

class _JoiningScreenState extends ConsumerState<JoiningScreen> {
  /// The scheduler starts a run the moment a sign-in lands, and this waits on
  /// that one: two runs against an unreconciled account is how a row is filed
  /// twice.
  bool _sawRun = false;
  bool _done = false;

  Timer? _cap;

  @override
  void initState() {
    super.initState();
    _cap = Timer(JoiningScreen.wait, _finish);
  }

  @override
  void dispose() {
    _cap?.cancel();
    super.dispose();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _cap?.cancel();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final SyncStatus status = ref.watch(syncStatusProvider);
    if (status.state == SyncState.running) _sawRun = true;

    // A run that finished before this screen was built still counts: the
    // controller clears the status when the account changes, so anything
    // recorded here belongs to the run signing in started.
    final bool onboarded = ref.watch(settingsProvider.select(
      (AsyncValue<AppSettings> s) => s.value?.onboarded ?? false,
    ));
    final bool ended = status.state != SyncState.running &&
        (_sawRun || status.lastRunAt != null || status.failure != null);
    if (onboarded || ended) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _finish();
      });
    }

    return Scaffold(
      backgroundColor: widget.colors.canvas,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: widget.colors.accent,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                JoiningScreen.heading,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: widget.colors.text,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                JoiningScreen.caption,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: widget.colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
