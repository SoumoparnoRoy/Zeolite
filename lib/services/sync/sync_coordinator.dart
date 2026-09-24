import 'package:flutter/foundation.dart';

import '../../data/db/zeolite_repository.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/sync/sync_merge.dart';
import '../../domain/sync/sync_plan.dart';
import '../../domain/sync/sync_status.dart';
import '../../domain/sync/sync_target.dart';

import 'remote_fields.dart';
import 'sync_identity_adoption.dart';
import 'sync_local_rows.dart';
import 'sync_pull_applier.dart';
import 'sync_stray_store.dart';

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
    this.pulledKeys = const <SyncKind, List<String>>{},
    this.archived = 0,
    this.overwritten = 0,
    this.unreadable = 0,
    this.review = const <SyncPull>[],
    this.failure,
    this.message,
  });

  final SyncRunOutcome outcome;
  final int pushed;
  final int pulled;

  /// Which rows [pulled] counted, by kind. Undo needs them by name — see
  /// `ActionCore._pulledSinceUndo`.
  final Map<SyncKind, List<String>> pulledKeys;

  final int archived;

  /// Rows changed in both places where this device's copy won. Counted
  /// because the far side's version is gone and the user should be told.
  final int overwritten;

  /// Rows the account holds that no version of this app could have written,
  /// passed over so the rest still apply. Counted because a row that is left
  /// behind without a word looks exactly like one that synced.
  final int unreadable;

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
    required SettingsService settings,
    required this.target,
    SyncBackoff backoff = const SyncBackoff(),
    DateTime Function() now = DateTime.now,
    SyncStrayStore? strays,
  })  : _repository = repository,
        _strayStore = strays ?? SyncStrayStore(),
        _settings = settings,
        _backoff = backoff,
        _now = now,
        _pulls = SyncPullApplier(
          repository: repository,
          settings: settings,
          target: target,
          now: now,
        ),
        _adoption = SyncIdentityAdoption(repository);

  final ZeoliteRepository _repository;
  final SettingsService _settings;
  final SyncTarget target;
  final SyncBackoff _backoff;
  final DateTime Function() _now;
  final SyncPullApplier _pulls;
  final SyncIdentityAdoption _adoption;
  final SyncStrayStore _strayStore;

  SyncStatus _status = const SyncStatus();
  SyncStatus get status => _status;

  /// When a run was last *attempted*, which is not [SyncStatus.lastRunAt] —
  /// that only moves on success, so backing off from it would never hold
  /// anything back until a run had succeeded at least once.
  DateTime? _attemptedAt;

  Future<SyncRunResult>? _inFlight;

  /// One re-run covers any number of collapsed requests.
  bool _rerunWanted = false;

  /// Parents before children, because every reference travels as the far
  /// side's key and a row that arrives first would point at nothing: a mark is
  /// keyed on its subject, a slot names its subject, a subject names its
  /// category and a mark names its tag.
  /// [_order] filtered to what the target keeps, which is every kind for an
  /// account and attendance alone for Notion.
  List<SyncKind> get _kinds =>
      _order.where(target.kinds.contains).toList(growable: false);

  static const List<SyncKind> _order = <SyncKind>[
    SyncKind.settings,
    SyncKind.category,
    SyncKind.room,
    SyncKind.tag,
    SyncKind.holiday,
    SyncKind.subject,
    SyncKind.slot,
    SyncKind.extraClass,
    SyncKind.slotOverride,
    SyncKind.attendance,
  ];

  /// What counts as "this side holds something" when deciding whether to ask.
  ///
  /// The question exists to protect history, and settings, categories, rooms
  /// and tags are not history: the settings row exists from first launch and
  /// the app seeds categories itself, so counting any of them would make an
  /// empty side impossible and put every fresh install through a merge with
  /// nothing to merge. They also all key on a name, so they combine without a
  /// decision anyway.
  static const List<SyncKind> _content = <SyncKind>[
    SyncKind.holiday,
    SyncKind.subject,
    SyncKind.slot,
    SyncKind.extraClass,
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

  /// What the two sides hold, with no ledger between them — the question the
  /// merge screen exists to answer. Reads both sides and writes nothing, so it
  /// is safe to open, back out of, and open again.
  ///
  /// Null when the account could not be read: offering a merge against a side
  /// that failed to load would show every local row as unique and invite the
  /// user to "resolve" a difference that does not exist.
  Future<SyncMergePlan?> previewMerge() async {
    final SyncLocalRows local =
        await SyncLocalRows.read(_repository, _settings);
    final List<SyncMergeRow> onlyHere = <SyncMergeRow>[];
    final List<SyncMergeRow> onlyThere = <SyncMergeRow>[];
    final List<SyncMergeRow> differing = <SyncMergeRow>[];
    final List<SyncMergeRow> agreed = <SyncMergeRow>[];

    for (final SyncKind kind in _kinds) {
      final List<RemoteState>? remote = await target.fetch(kind);
      if (remote == null) return null;
      final SyncMergePlan part =
          SyncMergePlan.from(local: local.items[kind]!, remote: remote);
      onlyHere.addAll(part.onlyHere);
      onlyThere.addAll(part.onlyThere);
      differing.addAll(part.differing);
      agreed.addAll(part.agreed);
    }

    return SyncMergePlan(
      onlyHere: onlyHere,
      onlyThere: onlyThere,
      differing: differing,
      agreed: agreed,
    );
  }

  /// [merge] holds one decision per differing key. Its presence is also what
  /// says the first-run question has been answered, so the check below stands
  /// down rather than asking again and looping.
  ///
  /// One run at a time, because a target that creates by call rather than by
  /// key files a second page for every row two overlapping runs both see as
  /// unlinked.
  Future<SyncRunResult> run({
    bool force = false,
    Map<String, SyncSide>? merge,
    bool rewrite = false,
  }) {
    final Future<SyncRunResult>? inFlight = _inFlight;
    if (inFlight == null) {
      return _start(force: force, merge: merge, rewrite: rewrite);
    }

    // Only a run started with the answer can apply it.
    if (merge != null || rewrite) {
      return _queueAfter(inFlight,
          force: force, merge: merge, rewrite: rewrite);
    }

    // Local rows may have moved since the running one read them.
    _rerunWanted = true;
    return inFlight;
  }

  Future<SyncRunResult> _start({
    required bool force,
    required Map<String, SyncSide>? merge,
    bool rewrite = false,
  }) {
    final Future<SyncRunResult> attempt =
        _run(force: force, merge: merge, rewrite: rewrite);
    _inFlight = attempt;
    return attempt.whenComplete(() {
      _inFlight = null;
      if (!_rerunWanted) return;
      _rerunWanted = false;
      // Nobody awaits this one, so a failure would go unhandled.
      _start(force: false, merge: null).then<void>((_) {}, onError: (_, __) {});
    });
  }

  Future<SyncRunResult> _queueAfter(
    Future<SyncRunResult> previous, {
    required bool force,
    required Map<String, SyncSide>? merge,
    bool rewrite = false,
  }) async {
    await previous.then<void>((_) {}, onError: (_, __) {});
    return run(force: force, merge: merge, rewrite: rewrite);
  }

  Future<SyncRunResult> _run({
    bool force = false,
    Map<String, SyncSide>? merge,
    bool rewrite = false,
  }) async {
    try {
      return await _attempt(force: force, merge: merge, rewrite: rewrite);
    } catch (error, stack) {
      // Anything unforeseen still has to end the run, or the status stays on
      // running and every later run is turned away as already in progress.
      debugPrint('Sync run failed: $error\n$stack');
      _status = _status.failed(SyncFailure.unknown);
      return const SyncRunResult(
        outcome: SyncRunOutcome.failed,
        failure: SyncFailure.unknown,
      );
    }
  }

  Future<SyncRunResult> _attempt({
    required bool force,
    required Map<String, SyncSide>? merge,
    required bool rewrite,
  }) async {
    if (!force && !canRunNow()) {
      return const SyncRunResult(outcome: SyncRunOutcome.deferred);
    }
    _status = _status.running();
    _attemptedAt = _now();

    final Map<SyncKind, List<RemoteLink>> links = <SyncKind, List<RemoteLink>>{
      for (final SyncKind kind in _kinds)
        kind: await _repository.getRemoteLinks(target.id, kind),
    };
    final Map<SyncKind, List<RemoteState>?> remote =
        <SyncKind, List<RemoteState>?>{
      for (final SyncKind kind in _kinds) kind: await target.fetch(kind),
    };

    // Ahead of the local read and of the check below, which would otherwise
    // call two reconcilable sides disjoint.
    await _adoptAccountIdentities(links, remote);

    final SyncLocalRows read = await SyncLocalRows.read(_repository, _settings);
    final Map<SyncKind, List<SyncItem>> local = read.items;
    final Map<SyncKind, List<RemoteState>> disputed =
        await _claimUnkeyedRows(local, links, remote);

    // [rewrite] is the user having already answered this: they asked for the
    // far side to be written over. Without it, forgetting the ledger to force
    // a rewrite looks exactly like a first run with data on both sides, and
    // the rewrite turns into the question it was meant to settle.
    if (merge == null &&
        !rewrite &&
        _firstRunMerge(local, links, remote) == _Merge.review) {
      _status = _status.succeeded(_now());
      return SyncRunResult(
        outcome: SyncRunOutcome.reviewNeeded,
        review: <SyncPull>[
          for (final SyncKind kind in _kinds)
            for (final RemoteState state in remote[kind]!)
              SyncPull(remote: state),
        ],
      );
    }

    final bool joining = _joiningAnAccount(local, links, remote);

    final _Tally tally = _Tally();
    for (final SyncKind kind in _kinds) {
      final SyncFailure? stop = await _runKind(
        kind: kind,
        items: local[kind]!,
        links: links[kind]!,
        remote: remote[kind],
        disputed: disputed[kind] ?? const <RemoteState>[],
        local: read,
        merge: merge,
        tally: tally,
        joining: joining,
        rewrite: rewrite,
      );
      if (stop != null) {
        _status = _status.failed(stop, message: tally.message);
        return SyncRunResult(
          outcome: SyncRunOutcome.failed,
          pushed: tally.pushed,
          pulled: tally.pulled,
          archived: tally.archived,
          overwritten: tally.overwritten,
          unreadable: tally.unreadable,
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
      pulledKeys: tally.pulledKeys,
      archived: tally.archived,
      overwritten: tally.overwritten,
      unreadable: tally.unreadable,
      review: tally.review,
    );
  }

  /// Returns the failure that ended the run early, or null if it finished.
  Future<SyncFailure?> _runKind({
    required SyncKind kind,
    required List<SyncItem> items,
    required List<RemoteLink> links,
    required List<RemoteState>? remote,
    required SyncLocalRows local,
    required Map<String, SyncSide>? merge,
    required _Tally tally,
    List<RemoteState> disputed = const <RemoteState>[],
    bool joining = false,
    bool rewrite = false,
  }) async {
    // A row of theirs that says something else about a class this device also
    // holds. Left out of the plan and put to the user instead: pushing would
    // write over what they typed, and creating would file the same class
    // twice.
    final Set<String> held = <String>{};
    for (final RemoteState state in disputed) {
      held.add(state.localKey);
      tally.review.add(SyncPull(remote: state, claimed: true));
    }
    if (held.isNotEmpty) {
      items = <SyncItem>[
        for (final SyncItem item in items)
          if (!held.contains(item.localKey)) item,
      ];
    }

    final SyncPlan plan = SyncPlan.from(
      local: items,
      links: links,
      remote: remote,
      recreateMissing: target.recreatesMissingRows,
      ownsRows: target.ownsEveryRow,
    );
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
      final RemoteLink? link;
      try {
        link = await _pulls.apply(pull, kind, local);
      } on UnreadableRow {
        tally.unreadable++;
        continue;
      }
      if (link == null) {
        forget.add(pull.remote.localKey);
      } else {
        write.add(link);
      }
      tally.pull(kind, pull.remote.localKey);
    }

    for (final SyncPush push in plan.pushes) {
      final RemoteState? state = remoteByKey[push.item.localKey];
      // With no ledger every shared row plans as an adopt, so a merge decision
      // of "keep the account's copy" has to be honoured here — otherwise the
      // push would send the local row the user just chose against.
      final bool chosenAway =
          merge?[push.item.localKey] == SyncSide.there && state != null;
      // Outside [_content], a joining device is holding defaults, not answers.
      final bool defaultsHere = joining &&
          push.kind == SyncPushKind.adopt &&
          !_content.contains(kind) &&
          state != null &&
          !_reusesABuriedName(push.item, state);
      // Made on both sides before either synced it, so there is no link to
      // call it a conflict, but it is one. A merge answer or a rewrite has
      // already said which side to keep.
      final bool newerThere = push.kind == SyncPushKind.adopt &&
          merge == null &&
          !rewrite &&
          _content.contains(kind) &&
          _remoteWins(push.item, state);
      if (chosenAway ||
          defaultsHere ||
          newerThere ||
          (push.kind == SyncPushKind.conflict &&
              _remoteWins(push.item, state))) {
        final RemoteLink? link;
        try {
          link = await _pulls.apply(
            SyncPull(remote: state!, link: push.link),
            kind,
            local,
          );
        } on UnreadableRow {
          tally.unreadable++;
          continue;
        }
        if (link == null) {
          forget.add(state.localKey);
        } else {
          write.add(link);
        }
        tally.pull(kind, state.localKey);
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
        final SyncOutcome outcome =
            await target.archive(kind, drop.link.remoteId);
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

  /// Whether a local row only shares its name with a tombstone rather than
  /// being the thing that was buried — a name renamed back, or seeded as a
  /// default since. Without this a joining device deletes a row it made
  /// tonight on the word of a deletion from months ago. Only categories carry
  /// a creation time, so only they can be told apart.
  bool _reusesABuriedName(SyncItem item, RemoteState state) {
    final DateTime? buried = state.editedAt;
    final DateTime? made = item.changedAt;
    if (!state.deleted || buried == null || made == null) return false;
    return made.isAfter(buried);
  }

  /// Settles rows a person answered on, for a target whose pulls are never
  /// applied on their own.
  ///
  /// [SyncSide.here] clears the link's local hash, which is how this design
  /// says "needs pushing". Either way the remote hash is brought up to date,
  /// so an answered difference is not raised again.
  Future<int> applyReview(
    List<SyncPull> pulls,
    Map<String, SyncSide> decisions,
  ) async {
    if (pulls.isEmpty) return 0;
    final SyncLocalRows read = await SyncLocalRows.read(_repository, _settings);
    final List<RemoteLink> write = <RemoteLink>[];
    final List<String> forget = <String>[];
    int settled = 0;

    for (final SyncPull pull in pulls) {
      final SyncSide? side = decisions[pull.remote.localKey];
      if (side == null) continue;
      settled++;

      if (side == SyncSide.there) {
        final RemoteLink? link;
        try {
          link = await _pulls.apply(pull, SyncKind.attendance, read);
        } on UnreadableRow {
          settled--;
          continue;
        }
        if (link == null) {
          forget.add(pull.remote.localKey);
          continue;
        }
        // A claimed row is linked here but still unkeyed there. If the key
        // cannot go now, a push next run carries it with the values just
        // taken, which are theirs anyway.
        final bool keyed = !pull.claimed ||
            (await target.writeKey(
              SyncKind.attendance,
              pull.remote.localKey,
              pull.remote.remoteId,
            ))
                .ok;
        write.add(keyed ? link : link.copyWith(localHash: ''));
        continue;
      }

      final RemoteLink? link = pull.link;
      final SyncItem? mine = link == null
          ? read.items[SyncKind.attendance]!
              .where((SyncItem item) => item.localKey == pull.remote.localKey)
              .firstOrNull
          : null;

      // A page with no link and no mark here has nothing to keep, so there is
      // nothing to mark as needing a push — and a rewrite cannot make a link
      // for a mark that does not exist. Left alone it was offered again on
      // every run forever, so "mine wins" retires it instead. Trashed, not
      // deleted.
      if (link == null && mine == null) {
        final SyncOutcome outcome =
            await target.archive(SyncKind.attendance, pull.remote.remoteId);
        if (!outcome.ok) settled--;
        continue;
      }

      // A row of theirs this device was recognised in has no link yet, so one
      // is made here. An empty local hash is what says it still needs pushing,
      // and the push is what puts the user's own answer into their row.
      write.add(
        link?.copyWith(
              localHash: '',
              remoteHash: pull.remote.hash,
              syncedAt: _now(),
            ) ??
            RemoteLink(
              target: target.id,
              kind: SyncKind.attendance,
              localKey: pull.remote.localKey,
              remoteId: pull.remote.remoteId,
              localHash: '',
              remoteHash: pull.remote.hash,
              origin: SyncOrigin.remote,
              syncedAt: _now(),
            ),
      );
    }

    await _commit(SyncKind.attendance, write, forget);
    return settled;
  }

  /// The run that follows an answer, queued rather than joined: one already
  /// in flight planned against the ledger as it stood before the answers
  /// landed, and would leave a kept row waiting.
  Future<SyncRunResult> runAfterReview() {
    final Future<SyncRunResult>? inFlight = _inFlight;
    return inFlight == null
        ? _start(force: true, merge: null)
        : _queueAfter(inFlight, force: true, merge: null);
  }

  Future<void> _commit(
    SyncKind kind,
    List<RemoteLink> write,
    List<String> forget,
  ) async {
    await _repository.transaction((ZeoliteRepository repository) async {
      await repository.deleteRemoteLinks(target.id, kind, forget);
      await repository.setRemoteLinks(write);
    });
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

  /// Hands a local subject the identity the account files its code under.
  ///
  /// A restore from a pre-v8 backup issues every subject a fresh uuid, so
  /// signing in afterwards offers the account a second copy of a term it
  /// already holds, marks and slots included. The code is the only evidence
  /// the two rows are one course — and only on a first run, since once a
  /// ledger exists an unknown uuid means a subject genuinely added here.
  Future<void> _adoptAccountIdentities(
    Map<SyncKind, List<RemoteLink>> links,
    Map<SyncKind, List<RemoteState>?> remote,
  ) async {
    if (_kinds.any((SyncKind k) => links[k]!.isNotEmpty)) return;
    await _adoption.adopt(remote);
  }

  /// Folds into [remote] the rows a person kept on the far side before this
  /// app wrote any key there, matched to the local rows nothing links yet.
  /// Without it a table filled in by hand gets every class a second time the
  /// moment its key column exists.
  /// Returns the claimed rows that disagree with the local row they were
  /// recognised in, for the caller to put to the user.
  Future<Map<SyncKind, List<RemoteState>>> _claimUnkeyedRows(
    Map<SyncKind, List<SyncItem>> local,
    Map<SyncKind, List<RemoteLink>> links,
    Map<SyncKind, List<RemoteState>?> remote,
  ) async {
    final Map<SyncKind, List<RemoteState>> disputed =
        <SyncKind, List<RemoteState>>{};
    for (final SyncKind kind in _kinds) {
      List<RemoteState>? known = remote[kind];
      if (known == null) continue;
      final Set<String> strays = await _strays(kind, known, local, links);
      if (strays.isNotEmpty) {
        known = <RemoteState>[
          for (final RemoteState state in known)
            if (!strays.contains(state.remoteId)) state,
        ];
        remote[kind] = known;
      }
      final Set<String> taken = <String>{
        for (final RemoteLink link in links[kind]!) link.localKey,
        for (final RemoteState state in known) state.localKey,
      };
      final List<SyncItem> unlinked = <SyncItem>[
        for (final SyncItem item in local[kind]!)
          if (!taken.contains(item.localKey)) item,
      ];
      if (unlinked.isEmpty) continue;
      final List<SyncClaim> claimed =
          await target.claim(kind, unlinked, strays: strays);
      if (claimed.isEmpty) continue;

      remote[kind] = <RemoteState>[
        ...known,
        for (final SyncClaim claim in claimed)
          if (claim.agrees) claim.state,
      ];
      final List<RemoteState> differing = <RemoteState>[
        for (final SyncClaim claim in claimed)
          if (!claim.agrees) claim.state,
      ];
      if (differing.isNotEmpty) disputed[kind] = differing;
    }
    return disputed;
  }

  /// Marks on the far side whose key names a subject this device has never
  /// held — left by an install since wiped, so every key still points at
  /// the old one. As good as unkeyed: claimed for the marks the new subjects
  /// hold, instead of pulled as strangers while every class is filed again.
  /// Only where a person keeps the table; a store this app owns pulls them.
  ///
  /// A device with no links there yet is what a wiped install is, so that
  /// run takes every unknown subject and remembers which they were. Later
  /// runs take only those: a claim still in review, or a row whose class has
  /// not been marked here yet, keeps its old key — pushed or pulled as a
  /// stranger, it would be filed twice. Any other subject is left alone, or
  /// two devices writing one table without an account between them would
  /// take each other's rows back and forth every run.
  Future<Set<String>> _strays(
    SyncKind kind,
    List<RemoteState> known,
    Map<SyncKind, List<SyncItem>> local,
    Map<SyncKind, List<RemoteLink>> links,
  ) async {
    if (kind != SyncKind.attendance || target.trustsPulls) {
      return const <String>{};
    }
    String subjectOf(String key) => key.split(':').first;
    final Set<String> linked = <String>{
      for (final RemoteLink link in links[kind]!) link.localKey,
    };
    final Set<String> subjects = <String>{
      for (final SyncItem item in local[kind]!) subjectOf(item.localKey),
      for (final String key in linked) subjectOf(key),
      for (final SyncItem item in local[SyncKind.subject] ?? const <SyncItem>[])
        item.localKey,
    };
    final List<RemoteState> unknown = <RemoteState>[
      for (final RemoteState state in known)
        if (!linked.contains(state.localKey) &&
            !subjects.contains(subjectOf(state.localKey)))
          state,
    ];
    final Set<String> old;
    if (linked.isEmpty) {
      old = <String>{
        for (final RemoteState state in unknown) subjectOf(state.localKey),
      };
      await _strayStore.save(target.id, old);
    } else {
      old = await _strayStore.load(target.id);
    }
    return <String>{
      for (final RemoteState state in unknown)
        if (old.contains(subjectOf(state.localKey))) state.remoteId,
    };
  }

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
    final bool linked = _kinds.any((SyncKind k) => links[k]!.isNotEmpty);
    if (linked) return _Merge.proceed;

    final bool hasLocal = _content.any((SyncKind k) => local[k]!.isNotEmpty);
    return hasLocal && _remoteHasContent(remote)
        ? _Merge.review
        : _Merge.proceed;
  }

  /// A device signing in to an account that already holds a term, carrying no
  /// history and no ledger of its own. Its settings row and seeded categories
  /// are whatever onboarding defaulted to rather than anything chosen, and
  /// `changedAt` cannot arbitrate: onboarding stamps the schedule as it sets
  /// the dates, so this side always looks newer.
  bool _joiningAnAccount(
    Map<SyncKind, List<SyncItem>> local,
    Map<SyncKind, List<RemoteLink>> links,
    Map<SyncKind, List<RemoteState>?> remote,
  ) {
    if (_kinds.any((SyncKind k) => links[k]!.isNotEmpty)) return false;
    if (_content.any((SyncKind k) => local[k]!.isNotEmpty)) return false;
    return _remoteHasContent(remote);
  }

  bool _remoteHasContent(Map<SyncKind, List<RemoteState>?> remote) =>
      _content.every((SyncKind k) => remote[k] != null) &&
      _content.any((SyncKind k) => remote[k]!.isNotEmpty);
}

enum _Merge { proceed, review }

class _Tally {
  int pushed = 0;
  int pulled = 0;
  int archived = 0;
  int overwritten = 0;
  int unreadable = 0;
  String? message;
  final List<SyncPull> review = <SyncPull>[];

  final Map<SyncKind, List<String>> pulledKeys = <SyncKind, List<String>>{};

  void pull(SyncKind kind, String localKey) {
    pulled++;
    pulledKeys.putIfAbsent(kind, () => <String>[]).add(localKey);
  }
}
