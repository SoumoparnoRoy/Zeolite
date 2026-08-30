import '../../core/date_utils.dart';
import '../../domain/sync/sync_status.dart';
import '../../domain/sync/sync_target.dart';
import '../../services/sync/sync_coordinator.dart';

/// The one line Settings shows for a target.
///
/// Shared by the account and by Notion so the two never drift into
/// describing the same state differently, and out of both widgets so the
/// wording can be pinned down without a Firebase user.
String syncStatusLine(
  SyncStatus status,
  SyncRunResult? last, {
  DateTime? storedLastSyncAt,
  String authAdvice = 'Sign out and back in, then try again.',
}) {
  switch (status.state) {
    case SyncState.running:
      return 'Syncing…';
    case SyncState.offline:
      return 'No connection. Your attendance is safe on this device.';
    case SyncState.failed:
      // The advice differs by target — an account is signed into, a workspace
      // is connected — and sending someone to the wrong one is worse than
      // saying nothing.
      return status.failure == SyncFailure.auth
          ? 'The last sync was refused. $authAdvice'
          : 'The last sync did not finish. Nothing on this device changed.';
    case SyncState.idle:
      if (last?.outcome == SyncRunOutcome.reviewNeeded) {
        // Never a bare "synced": nothing was merged, and the difference is
        // still sitting there waiting on an answer.
        return 'This device and your account both hold attendance. Nothing '
            'has been changed yet.';
      }
      // Rebuilt with the process, so the stored stamp outlives it.
      final DateTime? at = status.lastRunAt ?? storedLastSyncAt;
      if (at == null) return 'Not synced yet.';
      return 'Synced ${_ago(at)}.${_counts(last)}';
  }
}

String _counts(SyncRunResult? last) {
  if (last == null) return '';
  final List<String> parts = <String>[
    if (last.pushed > 0) '${last.pushed} sent',
    if (last.pulled > 0) '${last.pulled} received',
    if (last.overwritten > 0) '${last.overwritten} replaced there',
    // Removals are counted too, or unmarking a class reads exactly like a run
    // that did nothing at all.
    if (last.archived > 0) '${last.archived} removed there',
  ];
  return parts.isEmpty ? '' : ' ${parts.join(', ')}.';
}

String _ago(DateTime at) {
  final Duration since = DateTime.now().difference(at);
  if (since.inMinutes < 1) return 'just now';
  if (since.inMinutes < 60) return '${since.inMinutes} min ago';
  if (since.inHours < 24) return '${since.inHours} h ago';
  return 'on ${Dates.formatDayMonth(at)}';
}
