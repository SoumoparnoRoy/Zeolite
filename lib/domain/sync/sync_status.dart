import 'package:flutter/foundation.dart';

import 'sync_target.dart';

enum SyncState { idle, running, failed, offline }

/// Where a target stands, as Settings shows it.
///
/// A failure is a line with a Retry, never a modal and never a blocked write:
/// marking has already succeeded locally by the time any of this runs.
@immutable
class SyncStatus {
  const SyncStatus({
    this.state = SyncState.idle,
    this.lastRunAt,
    this.failure,
    this.message,
    this.failures = 0,
  });

  final SyncState state;

  /// Last run that finished without error, which is what "synced 5 min ago"
  /// reads from.
  final DateTime? lastRunAt;

  final SyncFailure? failure;
  final String? message;

  /// Consecutive failures, and so the exponent the backoff uses.
  final int failures;

  SyncStatus running() => SyncStatus(
        state: SyncState.running,
        lastRunAt: lastRunAt,
        failures: failures,
      );

  SyncStatus succeeded(DateTime at) =>
      SyncStatus(state: SyncState.idle, lastRunAt: at);

  SyncStatus failed(SyncFailure failure, {String? message}) => SyncStatus(
        state: failure == SyncFailure.offline
            ? SyncState.offline
            : SyncState.failed,
        lastRunAt: lastRunAt,
        failure: failure,
        message: message,
        failures: failures + 1,
      );
}

/// How long to wait before trying again.
///
/// Capped rather than unbounded because the app has to stay usable while a
/// target is down, and a run that has failed eight times will not be fixed by
/// waiting eight hours.
@immutable
class SyncBackoff {
  const SyncBackoff({
    this.base = const Duration(seconds: 30),
    this.cap = const Duration(minutes: 30),
  });

  final Duration base;
  final Duration cap;

  Duration delayFor(int failures) {
    if (failures <= 0) return Duration.zero;
    // Shifting past the cap's own magnitude would overflow the multiplication
    // long before it ever reached it.
    final int steps = failures - 1 > 20 ? 20 : failures - 1;
    final Duration delay = base * (1 << steps);
    return delay > cap ? cap : delay;
  }
}
