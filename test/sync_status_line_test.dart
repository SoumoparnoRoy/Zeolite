import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/sync/sync_status.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/features/settings/sync_status_line.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';

/// A run that reports "synced" when it merged nothing is the failure mode
/// worth guarding: the user would believe two devices agree when they do not.
void main() {
  final DateTime justNow = DateTime.now();

  test('a run that refused to merge says so instead of claiming success', () {
    final String line = syncStatusLine(
      SyncStatus(state: SyncState.idle, lastRunAt: justNow),
      const SyncRunResult(outcome: SyncRunOutcome.reviewNeeded),
    );

    expect(line, contains('Nothing'));
    expect(line, isNot(contains('Synced')));
  });

  test('a finished run names what moved, and in which direction', () {
    final String line = syncStatusLine(
      SyncStatus(state: SyncState.idle, lastRunAt: justNow),
      const SyncRunResult(
        outcome: SyncRunOutcome.synced,
        pushed: 3,
        pulled: 1,
        overwritten: 2,
      ),
    );

    expect(line, contains('3 sent'));
    expect(line, contains('1 received'));
    expect(line, contains('2 replaced there'));
  });

  test('a run that moved nothing does not pad the line with zeroes', () {
    final String line = syncStatusLine(
      SyncStatus(state: SyncState.idle, lastRunAt: justNow),
      const SyncRunResult(outcome: SyncRunOutcome.synced),
    );

    expect(line, 'Synced just now.');
  });

  test('the line goes on ageing while the screen stays open', () {
    final DateTime ran = DateTime(2026, 10, 4, 9);
    String at(Duration later) => syncStatusLine(
          SyncStatus(state: SyncState.idle, lastRunAt: ran),
          const SyncRunResult(outcome: SyncRunOutcome.synced),
          now: ran.add(later),
        );

    expect(at(Duration.zero), 'Synced just now.');
    expect(at(const Duration(minutes: 3)), 'Synced 3 min ago.');
    expect(at(const Duration(hours: 2)), 'Synced 2 h ago.');
  });

  test('rejection by the account tells the user what to do about it', () {
    final String line = syncStatusLine(
      const SyncStatus().failed(SyncFailure.auth),
      null,
    );

    expect(line, contains('Sign out'));
  });

  test('being offline never suggests anything was lost', () {
    final String line = syncStatusLine(
      const SyncStatus().failed(SyncFailure.offline),
      null,
    );

    expect(line, contains('safe on this device'));
  });

  test('a restart reports the stored run rather than denying it happened', () {
    final String line = syncStatusLine(
      const SyncStatus(),
      null,
      storedLastSyncAt: justNow.subtract(const Duration(minutes: 12)),
    );

    expect(line, 'Synced 12 min ago.');
  });

  test('a live run outranks the stored stamp', () {
    final String line = syncStatusLine(
      SyncStatus(state: SyncState.idle, lastRunAt: justNow),
      null,
      storedLastSyncAt: justNow.subtract(const Duration(hours: 5)),
    );

    expect(line, 'Synced just now.');
  });
}
