import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';
import '../../data/db/zeolite_repository.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../domain/sync/sync_plan.dart';
import '../../domain/sync/sync_status.dart';
import '../../domain/sync/sync_target.dart';

/// How a run ended.
enum SyncRunOutcome {
  synced,

  /// Both sides held data on a run that had no ledger to reconcile them with,
  /// so nothing was touched and the user has to say what should happen.
  reviewNeeded,

  /// Nothing ran because the previous failure's backoff has not elapsed.
  deferred,

  failed,
}

@immutable
class SyncRunResult {
  const SyncRunResult({
    required this.outcome,
    this.pushed = 0,
    this.pulled = 0,
    this.archived = 0,
    this.overwritten = 0,
    this.review = const <SyncPull>[],
    this.failure,
    this.message,
  });

  final SyncRunOutcome outcome;
  final int pushed;
  final int pulled;
  final int archived;

  /// Rows changed in both places where this device's copy won. Counted
  /// because the far side's version is gone and the user should be told.
  final int overwritten;

  /// Remote rows this run refused to apply on its own — everything from an
  /// untrusted target, and everything from a first run that found data on both
  /// sides. The preview screen consumes these; nothing here writes them.
  final List<SyncPull> review;

  final SyncFailure? failure;
  final String? message;

  bool get ok => outcome == SyncRunOutcome.synced;
}

/// Drives one [SyncTarget]: reads local rows, diffs them against the ledger,
/// runs the plan and writes `remote_links` back.
///
/// Deliberately the only place that knows a run has an order to it. Everything
/// below is either pure (the planner) or a single call (the target), and
/// nothing above has to understand either.
class SyncCoordinator {
  SyncCoordinator({
    required ZeoliteRepository repository,
    required this.target,
    SyncBackoff backoff = const SyncBackoff(),
    DateTime Function() now = DateTime.now,
  })  : _repository = repository,
        _backoff = backoff,
        _now = now;

  final ZeoliteRepository _repository;
  final SyncTarget target;
  final SyncBackoff _backoff;
  final DateTime Function() _now;

  SyncStatus _status = const SyncStatus();
  SyncStatus get status => _status;

  /// When a run was last *attempted*, which is not [SyncStatus.lastRunAt] —
  /// that only moves on success, so backing off from it would never hold
  /// anything back until a run had succeeded at least once.
  DateTime? _attemptedAt;

  /// Subjects before attendance, because a mark is keyed on its subject's uuid
  /// and a device receiving marks first would hold rows it cannot name.
  static const List<SyncKind> _order = <SyncKind>[
    SyncKind.subject,
    SyncKind.attendance,
  ];

  /// Whether the last failure's backoff has elapsed. A user-pressed run passes
  /// `force`, since waiting out a 30-minute cap in front of a Retry button is
  /// the opposite of what the button is for.
  bool canRunNow() {
    final DateTime? last = _attemptedAt;
    if (_status.failures == 0 || last == null) return true;
    return _now().difference(last) >= _backoff.delayFor(_status.failures);
  }

  Future<SyncRunResult> run({bool force = false}) async {
    if (!force && !canRunNow()) {
      return const SyncRunResult(outcome: SyncRunOutcome.deferred);
    }
    _status = _status.running();
    _attemptedAt = _now();

    final List<Subject> subjects = await _repository.getSubjects();
    final Map<int, String> uuidById = <int, String>{
      for (final Subject s in subjects)
        if (s.id != null && s.uuid != null) s.id!: s.uuid!,
    };
    final Map<String, Subject> subjectByUuid = <String, Subject>{
      for (final Subject s in subjects)
        if (s.uuid != null) s.uuid!: s,
    };

    final Map<SyncKind, List<SyncItem>> local = <SyncKind, List<SyncItem>>{
      SyncKind.subject: <SyncItem>[
        for (final Subject s in subjects)
          if (s.uuid != null) SyncItem.subject(s),
      ],
      SyncKind.attendance: <SyncItem>[
        for (final AttendanceRecord r in await _repository.getAttendance())
          if (uuidById[r.subjectId] != null)
            SyncItem.attendance(r, uuidById[r.subjectId]!),
      ],
    };

    final Map<SyncKind, List<RemoteLink>> links = <SyncKind, List<RemoteLink>>{
      for (final SyncKind kind in _order)
        kind: await _repository.getRemoteLinks(target.id, kind),
    };
    final Map<SyncKind, List<RemoteState>?> remote =
        <SyncKind, List<RemoteState>?>{
      for (final SyncKind kind in _order) kind: await target.fetch(kind),
    };

    final _Merge merge = _firstRunMerge(local, links, remote);
    if (merge == _Merge.review) {
      _status = _status.succeeded(_now());
      return SyncRunResult(
        outcome: SyncRunOutcome.reviewNeeded,
        review: <SyncPull>[
          for (final SyncKind kind in _order)
            for (final RemoteState state in remote[kind]!)
              SyncPull(remote: state),
        ],
      );
    }

    final _Tally tally = _Tally();
    for (final SyncKind kind in _order) {
      final SyncFailure? stop = await _runKind(
        kind: kind,
        local: local[kind]!,
        links: links[kind]!,
        remote: remote[kind],
        subjectByUuid: subjectByUuid,
        tally: tally,
      );
      if (stop != null) {
        _status = _status.failed(stop, message: tally.message);
        return SyncRunResult(
          outcome: SyncRunOutcome.failed,
          pushed: tally.pushed,
          pulled: tally.pulled,
          archived: tally.archived,
          overwritten: tally.overwritten,
          review: tally.review,
          failure: stop,
          message: tally.message,
        );
      }
    }

    _status = _status.succeeded(_now());
    return SyncRunResult(
      outcome: SyncRunOutcome.synced,
      pushed: tally.pushed,
      pulled: tally.pulled,
      archived: tally.archived,
      overwritten: tally.overwritten,
      review: tally.review,
    );
  }

  /// Returns the failure that ended the run early, or null if it finished.
  Future<SyncFailure?> _runKind({
    required SyncKind kind,
    required List<SyncItem> local,
    required List<RemoteLink> links,
    required List<RemoteState>? remote,
    required Map<String, Subject> subjectByUuid,
    required _Tally tally,
  }) async {
    final SyncPlan plan =
        SyncPlan.from(local: local, links: links, remote: remote);
    final Map<String, RemoteState> remoteByKey = <String, RemoteState>{
      for (final RemoteState state in remote ?? const <RemoteState>[])
        state.localKey: state,
    };

    final List<RemoteLink> write = <RemoteLink>[];
    final List<String> forget = <String>[];

    for (final SyncPull pull in plan.pulls) {
      if (!target.trustsPulls) {
        tally.review.add(pull);
        continue;
      }
      final RemoteLink? link = await _applyPull(pull, kind, subjectByUuid);
      if (link == null) {
        forget.add(pull.remote.localKey);
      } else {
        write.add(link);
      }
      tally.pulled++;
    }

    for (final SyncPush push in plan.pushes) {
      final RemoteState? state = remoteByKey[push.item.localKey];
      if (push.kind == SyncPushKind.conflict &&
          _remoteWins(push.item, state)) {
        final RemoteLink? link = await _applyPull(
          SyncPull(remote: state!, link: push.link),
          kind,
          subjectByUuid,
        );
        if (link == null) {
          forget.add(state.localKey);
        } else {
          write.add(link);
        }
        tally.pulled++;
        continue;
      }
      if (push.kind == SyncPushKind.conflict) tally.overwritten++;

      final String? remoteId = push.remoteId;
      final SyncOutcome outcome = remoteId == null
          ? await target.create(push.item)
          : await target.update(push.item, remoteId);
      if (!outcome.ok) {
        tally.message ??= outcome.message;
        if (_endsRun(outcome.failure!)) {
          await _commit(kind, write, forget);
          return outcome.failure;
        }
        continue;
      }
      write.add(
        RemoteLink(
          id: push.link?.id,
          target: target.id,
          kind: kind,
          localKey: push.item.localKey,
          remoteId: outcome.remoteId!,
          localHash: push.item.hash,
          remoteHash: outcome.remoteHash!,
          origin: push.link?.origin ?? _originFor(push.kind),
          syncedAt: _now(),
        ),
      );
      tally.pushed++;
    }

    for (final SyncDrop drop in plan.drops) {
      if (drop.kind == SyncDropKind.archive) {
        final SyncOutcome outcome = await target.archive(drop.link.remoteId);
        if (!outcome.ok) {
          tally.message ??= outcome.message;
          if (_endsRun(outcome.failure!)) {
            await _commit(kind, write, forget);
            return outcome.failure;
          }
          continue;
        }
        tally.archived++;
      }
      forget.add(drop.link.localKey);
    }

    await _commit(kind, write, forget);
    return null;
  }

  Future<void> _commit(
    SyncKind kind,
    List<RemoteLink> write,
    List<String> forget,
  ) async {
    await _repository.deleteRemoteLinks(target.id, kind, forget);
    await _repository.setRemoteLinks(write);
  }

  /// A row changed on both sides. "The app wins" was reasoned for a target
  /// [SyncTarget.trustsPulls] is false on, where the local mark is the
  /// deliberate act. Where it is true both sides are the same user, neither is
  /// more deliberate, and the later tap is simply the truer one.
  bool _remoteWins(SyncItem item, RemoteState? state) {
    if (!target.trustsPulls || state == null) return false;
    final DateTime? mine = item.changedAt;
    final DateTime? theirs = state.editedAt;
    // An undated remote row loses: it cannot be shown to be newer, and this
    // device at least knows the user was here.
    if (theirs == null) return false;
    if (mine == null) return true;
    return theirs.isAfter(mine);
  }

  /// Writes one remote row into the database, returning the link to record —
  /// or null when the row was a tombstone, where the link goes instead of
  /// being updated to describe something neither side holds.
  Future<RemoteLink?> _applyPull(
    SyncPull pull,
    SyncKind kind,
    Map<String, Subject> subjectByUuid,
  ) async {
    final RemoteState state = pull.remote;
    if (state.deleted) {
      await _deleteLocal(kind, state.localKey, subjectByUuid);
      return null;
    }

    final SyncItem? applied = switch (kind) {
      SyncKind.subject => await _applySubject(state, subjectByUuid),
      SyncKind.attendance => await _applyAttendance(state, subjectByUuid),
    };
    if (applied == null) return null;

    return RemoteLink(
      id: pull.link?.id,
      target: target.id,
      kind: kind,
      localKey: state.localKey,
      remoteId: state.remoteId,
      // Taken from what was actually written rather than from the remote hash:
      // anything the local row cannot hold has to show as a difference on the
      // next run, not be papered over here.
      localHash: applied.hash,
      remoteHash: state.hash,
      origin: pull.link?.origin ?? SyncOrigin.remote,
      syncedAt: _now(),
    );
  }

  Future<SyncItem?> _applySubject(
    RemoteState state,
    Map<String, Subject> subjectByUuid,
  ) async {
    final Subject? existing = subjectByUuid[state.localKey];
    final Map<String, Object?> f = state.fields;
    final String? name = f['name'] as String?;
    if (name == null || name.isEmpty) return null;

    final Subject subject = Subject(
      id: existing?.id,
      uuid: state.localKey,
      name: name,
      code: f['code'] as String?,
      teacher: f['teacher'] as String?,
      colorValue: _int(f['color']) ?? existing?.colorValue ?? 0xff607d8b,
      targetPercent: _double(f['targetPercent']),
      categoryId: existing?.categoryId,
      createdAt: state.editedAt ?? existing?.createdAt,
      priorHeld: _int(f['priorHeld']) ?? 0,
      priorAttended: _int(f['priorAttended']) ?? 0,
      expectedTotal: _int(f['expectedTotal']),
    );

    if (existing == null) {
      final int id = await _repository.insertSubject(subject);
      subjectByUuid[state.localKey] = subject.copyWith(id: id);
    } else {
      await _repository.updateSubject(subject);
      subjectByUuid[state.localKey] = subject;
    }
    return SyncItem.subject(subject);
  }

  Future<SyncItem?> _applyAttendance(
    RemoteState state,
    Map<String, Subject> subjectByUuid,
  ) async {
    final _MarkKey? key = _MarkKey.parse(state.localKey);
    final Subject? subject = key == null ? null : subjectByUuid[key.uuid];
    // A mark for a subject this device has never heard of. Subjects sync
    // first, so the only way here is a subject that failed to apply; the row
    // stays unlinked and the next run offers it again.
    if (key == null || subject?.id == null) return null;

    final AttendanceStatus? status =
        AttendanceStatus.fromName(state.fields['status'] as String?);
    if (status == null) return null;

    final AttendanceRecord record = AttendanceRecord(
      subjectId: subject!.id!,
      date: key.date,
      startMinutes: key.startMinutes,
      status: status,
      weight: _int(state.fields['weight']) ?? 1,
      note: state.fields['note'] as String?,
      markedAt: state.editedAt,
    );
    await _repository.setAttendance(record);
    return SyncItem.attendance(record, key.uuid);
  }

  Future<void> _deleteLocal(
    SyncKind kind,
    String localKey,
    Map<String, Subject> subjectByUuid,
  ) async {
    switch (kind) {
      case SyncKind.subject:
        final Subject? subject = subjectByUuid.remove(localKey);
        if (subject?.id != null) await _repository.deleteSubject(subject!.id!);
      case SyncKind.attendance:
        final _MarkKey? key = _MarkKey.parse(localKey);
        final Subject? subject = key == null ? null : subjectByUuid[key.uuid];
        if (key == null || subject?.id == null) return;
        await _repository.clearAttendance(
          subject!.id!,
          key.date,
          key.startMinutes,
        );
    }
  }

  /// A page found on the far side with no link is this app's own earlier push
  /// on a target only it writes to, so deleting the row here should take the
  /// page with it. Anywhere a person also writes, it is treated as theirs.
  SyncOrigin _originFor(SyncPushKind kind) =>
      kind == SyncPushKind.adopt && !target.trustsPulls
          ? SyncOrigin.remote
          : SyncOrigin.app;

  /// Whether one failed call means the rest of the run is pointless. Offline,
  /// rate limiting and a rejected sign-in are conditions on the whole target;
  /// a rejected or unexplained row is that row's problem, and one bad mark
  /// should not hold up a term of them.
  static bool _endsRun(SyncFailure failure) =>
      failure == SyncFailure.offline ||
      failure == SyncFailure.auth ||
      failure == SyncFailure.rateLimited;

  /// The first run against a target — no ledger at all — is the only time two
  /// populated sides cannot be told apart: with nothing recorded, every local
  /// row looks new and every remote row looks unseen, so merging would mean
  /// guessing. Either side empty has only one possible reading, so it goes
  /// through silently and a fresh install syncs without a question.
  _Merge _firstRunMerge(
    Map<SyncKind, List<SyncItem>> local,
    Map<SyncKind, List<RemoteLink>> links,
    Map<SyncKind, List<RemoteState>?> remote,
  ) {
    final bool linked =
        _order.any((SyncKind k) => links[k]!.isNotEmpty);
    if (linked) return _Merge.proceed;
    final bool hasLocal = _order.any((SyncKind k) => local[k]!.isNotEmpty);
    final bool hasRemote = _order.every((SyncKind k) => remote[k] != null) &&
        _order.any((SyncKind k) => remote[k]!.isNotEmpty);
    return hasLocal && hasRemote ? _Merge.review : _Merge.proceed;
  }
}

enum _Merge { proceed, review }

class _Tally {
  int pushed = 0;
  int pulled = 0;
  int archived = 0;
  int overwritten = 0;
  String? message;
  final List<SyncPull> review = <SyncPull>[];
}

/// The three parts of an attendance sync key, back out of the string.
@immutable
class _MarkKey {
  const _MarkKey(this.uuid, this.date, this.startMinutes);

  final String uuid;
  final DateTime date;
  final int startMinutes;

  static _MarkKey? parse(String key) {
    final List<String> parts = key.split(':');
    if (parts.length != 3) return null;
    final int? dateKey = int.tryParse(parts[1]);
    final int? start = int.tryParse(parts[2]);
    if (parts[0].isEmpty || dateKey == null || start == null) return null;
    return _MarkKey(parts[0], Dates.fromKey(dateKey), start);
  }
}

int? _int(Object? value) => switch (value) {
      int v => v,
      num v => v.round(),
      String v => int.tryParse(v),
      _ => null,
    };

double? _double(Object? value) => switch (value) {
      num v => v.toDouble(),
      String v => double.tryParse(v),
      _ => null,
    };
