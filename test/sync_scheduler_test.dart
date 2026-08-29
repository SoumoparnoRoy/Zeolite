import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/sync/sync_scheduler.dart';

/// The scheduler decides when a run happens, so what is worth pinning down is
/// the count: a burst of edits has to be one run, a resume inside the stale
/// window has to be none, and signing out has to leave nothing armed.
void main() {
  const Duration debounce = Duration(seconds: 15);
  const Duration staleAfter = Duration(minutes: 30);
  final DateTime start = DateTime(2026, 8, 29, 10);

  ({SyncScheduler scheduler, List<void> runs}) build(
    FakeAsync async, {
    DateTime? lastSyncAt,
  }) {
    final List<void> runs = <void>[];
    final SyncScheduler scheduler = SyncScheduler(
      run: () async => runs.add(null),
      lastSyncAt: () => lastSyncAt,
      debounce: debounce,
      staleAfter: staleAfter,
      now: () => start.add(async.elapsed),
    );
    return (scheduler: scheduler, runs: runs);
  }

  test('a burst of edits settles into one run after the last of them', () {
    fakeAsync((FakeAsync async) {
      final built = build(async, lastSyncAt: start);

      for (int i = 0; i < 6; i++) {
        built.scheduler.onLocalChange();
        async.elapse(const Duration(seconds: 3));
      }
      expect(built.runs, isEmpty, reason: 'still inside the window');

      async.elapse(debounce);
      expect(built.runs, hasLength(1));
    });
  });

  test('returning to a recently synced app does not fetch again', () {
    fakeAsync((FakeAsync async) {
      final built = build(async, lastSyncAt: start);
      async.elapse(const Duration(minutes: 5));

      built.scheduler.onResumed();
      async.flushTimers();

      expect(built.runs, isEmpty);
    });
  });

  test('returning after the staleness window runs', () {
    fakeAsync((FakeAsync async) {
      final built = build(async, lastSyncAt: start);
      async.elapse(staleAfter + const Duration(minutes: 1));

      built.scheduler.onResumed();
      async.flushTimers();

      expect(built.runs, hasLength(1));
    });
  });

  test('a cold start with no run behind it syncs', () {
    fakeAsync((FakeAsync async) {
      final built = build(async);

      built.scheduler.onResumed();
      async.flushTimers();

      expect(built.runs, hasLength(1));
    });
  });

  test('backgrounding flushes a pending run instead of dropping it', () {
    fakeAsync((FakeAsync async) {
      final built = build(async, lastSyncAt: start);

      built.scheduler.onLocalChange();
      async.elapse(const Duration(seconds: 2));
      built.scheduler.onPaused();

      expect(built.runs, hasLength(1));
      expect(built.scheduler.hasPendingRun, isFalse);
    });
  });

  test('backgrounding with nothing pending stays quiet', () {
    fakeAsync((FakeAsync async) {
      final built = build(async, lastSyncAt: start);

      built.scheduler.onPaused();
      async.flushTimers();

      expect(built.runs, isEmpty);
    });
  });

  test('signing out cancels the run the last edit armed', () {
    fakeAsync((FakeAsync async) {
      final built = build(async, lastSyncAt: start);

      built.scheduler.onLocalChange();
      built.scheduler.dispose();
      async.elapse(debounce * 2);

      expect(built.runs, isEmpty);
    });
  });
}
