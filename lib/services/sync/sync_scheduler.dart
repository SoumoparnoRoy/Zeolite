import 'dart:async';

import 'package:flutter/widgets.dart';

/// Decides when a sync run happens without the user asking for one. Both
/// triggers live here because "when does sync run" is one policy, and split
/// across a widget and the action layer neither half answers it.
class SyncScheduler {
  SyncScheduler({
    required Future<void> Function() run,
    required DateTime? Function() lastSyncAt,
    this.debounce = const Duration(seconds: 15),
    this.staleAfter = const Duration(minutes: 30),
    DateTime Function() now = DateTime.now,
  })  : _run = run,
        _lastSyncAt = lastSyncAt,
        _now = now;

  final Future<void> Function() _run;
  final DateTime? Function() _lastSyncAt;
  final DateTime Function() _now;

  /// Long enough that marking a whole day is one run rather than six.
  final Duration debounce;

  /// Matches the backoff cap, so an idle target is not asked more often than
  /// one that is down.
  final Duration staleAfter;

  Timer? _pending;
  AppLifecycleListener? _listener;

  void start() {
    _listener = AppLifecycleListener(onResume: onResumed, onPause: onPaused);
    // A process that has just started is already resumed, so the listener will
    // not report the resume that launching the app is.
    onResumed();
  }

  void dispose() {
    _pending?.cancel();
    _pending = null;
    _listener?.dispose();
    _listener = null;
  }

  /// Restarts the wait rather than extending it, so a burst of edits settles
  /// once after the last one.
  void onLocalChange() {
    _pending?.cancel();
    _pending = Timer(debounce, () {
      _pending = null;
      _run();
    });
  }

  void onResumed() {
    final DateTime? last = _lastSyncAt();
    if (last != null && _now().difference(last) < staleAfter) return;
    _run();
  }

  /// The timer dies with the process and the next resume would be inside the
  /// stale window, so a pending run is started rather than dropped.
  void onPaused() {
    if (_pending == null) return;
    _pending!.cancel();
    _pending = null;
    _run();
  }

  @visibleForTesting
  bool get hasPendingRun => _pending != null;
}
