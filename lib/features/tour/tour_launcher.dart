import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/report_error.dart';
import '../../data/settings/app_settings.dart';
import '../../state/providers.dart';
import 'tour_overlay.dart';
import 'tour_stops.dart';

/// Starts the tour once on a new install, and again whenever Settings asks.
///
/// Sits around the main shell, so it is only ever reached past the first-run
/// screens and the tour can't land on top of them.
class TourLauncher extends ConsumerStatefulWidget {
  const TourLauncher({super.key, required this.onPrepare, required this.child});

  /// Puts the stops on screen: Today, in its day view, with the bar showing.
  final VoidCallback onPrepare;
  final Widget child;

  @override
  ConsumerState<TourLauncher> createState() => _TourLauncherState();
}

class _TourLauncherState extends ConsumerState<TourLauncher> {
  bool _running = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<int>(
      tourReplayProvider,
      (int? _, int __) => unawaited(_run()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(settingsProvider).value?.tourSeen == false) {
        unawaited(_run());
      }
    });
  }

  /// Recorded at the end rather than the start, so an app closed halfway
  /// through shows it again next time.
  Future<void> _run() async {
    if (_running || !mounted) return;
    _running = true;
    try {
      widget.onPrepare();
      // The bar may be sliding back in, which moves the button above it; the
      // tour measures once that has settled. Nothing slides with reduced
      // motion on, so then one frame is enough.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (!MediaQuery.disableAnimationsOf(context)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
      }
      await showTour(context, ref.read(tourTargetsProvider));
      final AppSettings? current = ref.read(settingsProvider).value;
      if (current != null && !current.tourSeen) {
        await ref
            .read(settingsProvider.notifier)
            .save(current.copyWith(tourSeen: true));
      }
    } catch (error, stack) {
      reportError(error, stack, where: 'tour');
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
