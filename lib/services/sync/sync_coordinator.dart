import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';
import '../../data/db/zeolite_repository.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/class_category.dart';
import '../../data/models/class_slot.dart';
import '../../data/models/extra_class.dart';
import '../../data/models/holiday.dart';
import '../../data/models/room.dart';
import '../../data/models/subject.dart';
import '../../data/models/tag.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/restore_identity.dart';
import '../../domain/sync/sync_merge.dart';
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
    this.pulledKeys = const <SyncKind, List<String>>{},
    this.archived = 0,
    this.overwritten = 0,
    this.review = const <SyncPull>[],
    this.failure,
    this.message,
  });

  final SyncRunOutcome outcome;
  final int pushed;
  final int pulled;

  /// Which rows [pulled] counted, by kind. Undo needs them by name — see
  /// `TimetableActions._pulledSinceUndo`.
  final Map<SyncKind, List<String>> pulledKeys;

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
    required SettingsService settings,
    required this.target,
    SyncBackoff backoff = const SyncBackoff(),
    DateTime Function() now = DateTime.now,
  })  : _repository = repository,
        _settings = settings,
        _backoff = backoff,
        _now = now;

  final ZeoliteRepository _repository;
  final SettingsService _settings;
  final SyncTarget target;
  final SyncBackoff _backoff;
  final DateTime Function() _now;

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
    final _Local local = await _readLocal();
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
  }) {
    final Future<SyncRunResult>? inFlight = _inFlight;
    if (inFlight == null) return _start(force: force, merge: merge);

    // Only a run started with the answer can apply it.
    if (merge != null) return _queueAfter(inFlight, force: force, merge: merge);

    // Local rows may have moved since the running one read them.
    _rerunWanted = true;
    return inFlight;
  }

  Future<SyncRunResult> _start({
    required bool force,
    required Map<String, SyncSide>? merge,
  }) {
    final Future<SyncRunResult> attempt = _run(force: force, merge: merge);
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
  }) async {
    await previous.then<void>((_) {}, onError: (_, __) {});
    return run(force: force, merge: merge);
  }

  Future<SyncRunResult> _run({
    bool force = false,
    Map<String, SyncSide>? merge,
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

    final _Local read = await _readLocal();
    final Map<SyncKind, List<SyncItem>> local = read.items;

    if (merge == null && _firstRunMerge(local, links, remote) == _Merge.review) {
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
        local: read,
        merge: merge,
        tally: tally,
        joining: joining,
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
      pulledKeys: tally.pulledKeys,
      archived: tally.archived,
      overwritten: tally.overwritten,
      review: tally.review,
    );
  }

  /// The local side of a run, read once. A row whose parent has no key is left
  /// out entirely rather than sent under a local id — a subject with no uuid
  /// takes its marks and its slots down with it.
  Future<_Local> _readLocal() async {
    final List<Subject> subjects = await _repository.getSubjects();
    final List<ClassCategory> categories = await _repository.getCategories();
    final List<Room> rooms = await _repository.getRooms();
    final List<Tag> tags = await _repository.getTags();
    final List<Holiday> holidays = await _repository.getHolidays();
    final List<ClassSlot> slots = await _repository.getSlots();
    final List<ExtraClass> extras = await _repository.getExtraClasses();
    final AppSettings settings = await _settings.load();

    final Map<int, String> uuidById = <int, String>{
      for (final Subject s in subjects)
        if (s.id != null && s.uuid != null) s.id!: s.uuid!,
    };
    final Map<int, String> categoryNameById = <int, String>{
      for (final ClassCategory c in categories)
        if (c.id != null) c.id!: c.name,
    };
    final Map<int, String> tagNameById = <int, String>{
      for (final Tag t in tags)
        if (t.id != null) t.id!: t.name,
    };

    final _Local local = _Local(
      subjectByUuid: <String, Subject>{
        for (final Subject s in subjects)
          if (s.uuid != null) s.uuid!: s,
      },
      categoryByName: <String, ClassCategory>{
        for (final ClassCategory c in categories) c.name: c,
      },
      roomByName: <String, Room>{for (final Room r in rooms) r.name: r},
      tagByName: <String, Tag>{for (final Tag t in tags) t.name: t},
      holidayByKey: <String, Holiday>{
        for (final Holiday h in holidays) '${Dates.keyOf(h.date)}': h,
      },
      slotByUuid: <String, ClassSlot>{
        for (final ClassSlot s in slots)
          if (s.uuid != null) s.uuid!: s,
      },
      extraByUuid: <String, ExtraClass>{
        for (final ExtraClass e in extras)
          if (e.uuid != null) e.uuid!: e,
      },
    );

    local.items.addAll(<SyncKind, List<SyncItem>>{
      SyncKind.settings: <SyncItem>[
        SyncItem.settings(settings, changedAt: settings.scheduleChangedAt),
      ],
      SyncKind.category: <SyncItem>[
        for (final ClassCategory c in categories) SyncItem.category(c),
      ],
      SyncKind.room: <SyncItem>[for (final Room r in rooms) SyncItem.room(r)],
      SyncKind.tag: <SyncItem>[for (final Tag t in tags) SyncItem.tag(t)],
      SyncKind.holiday: <SyncItem>[
        for (final Holiday h in holidays) SyncItem.holiday(h),
      ],
      SyncKind.subject: <SyncItem>[
        for (final Subject s in subjects)
          if (s.uuid != null)
            SyncItem.subject(
              s,
              categoryName:
                  s.categoryId == null ? null : categoryNameById[s.categoryId],
            ),
      ],
      SyncKind.slot: <SyncItem>[
        for (final ClassSlot s in slots)
          if (s.uuid != null && uuidById[s.subjectId] != null)
            SyncItem.slot(s, uuidById[s.subjectId]!),
      ],
      SyncKind.extraClass: <SyncItem>[
        for (final ExtraClass e in extras)
          if (e.uuid != null && uuidById[e.subjectId] != null)
            SyncItem.extraClass(e, uuidById[e.subjectId]!),
      ],
      SyncKind.attendance: <SyncItem>[
        for (final AttendanceRecord r in await _repository.getAttendance())
          if (uuidById[r.subjectId] != null)
            SyncItem.attendance(
              r,
              uuidById[r.subjectId]!,
              tagName: r.tagId == null ? null : tagNameById[r.tagId],
            ),
      ],
    });

    return local;
  }

  /// Returns the failure that ended the run early, or null if it finished.
  Future<SyncFailure?> _runKind({
    required SyncKind kind,
    required List<SyncItem> items,
    required List<RemoteLink> links,
    required List<RemoteState>? remote,
    required _Local local,
    required Map<String, SyncSide>? merge,
    required _Tally tally,
    bool joining = false,
  }) async {
    final SyncPlan plan =
        SyncPlan.from(local: items, links: links, remote: remote);
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
      final RemoteLink? link = await _applyPull(pull, kind, local);
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
          state != null;
      if (chosenAway ||
          defaultsHere ||
          (push.kind == SyncPushKind.conflict &&
              _remoteWins(push.item, state))) {
        final RemoteLink? link = await _applyPull(
          SyncPull(remote: state!, link: push.link),
          kind,
          local,
        );
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
    final _Local read = await _readLocal();
    final List<RemoteLink> write = <RemoteLink>[];
    final List<String> forget = <String>[];
    int settled = 0;

    for (final SyncPull pull in pulls) {
      final SyncSide? side = decisions[pull.remote.localKey];
      if (side == null) continue;
      settled++;

      if (side == SyncSide.there) {
        final RemoteLink? link =
            await _applyPull(pull, SyncKind.attendance, read);
        if (link == null) {
          forget.add(pull.remote.localKey);
        } else {
          write.add(link);
        }
        continue;
      }

      // With no link there is nothing to mark: the page was never adopted
      // here, so leaving it be is the whole answer.
      final RemoteLink? link = pull.link;
      if (link == null) continue;
      write.add(
        link.copyWith(
          localHash: '',
          remoteHash: pull.remote.hash,
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
    _Local local,
  ) async {
    final RemoteState state = pull.remote;
    if (state.deleted) {
      await _deleteLocal(kind, state.localKey, local);
      return null;
    }

    final SyncItem? applied = switch (kind) {
      SyncKind.settings => await _applySettings(state),
      SyncKind.category => await _applyCategory(state, local),
      SyncKind.room => await _applyRoom(state, local),
      SyncKind.tag => await _applyTag(state, local),
      SyncKind.holiday => await _applyHoliday(state, local),
      SyncKind.subject => await _applySubject(state, local),
      SyncKind.slot => await _applySlot(state, local),
      SyncKind.extraClass => await _applyExtraClass(state, local),
      SyncKind.attendance => await _applyAttendance(state, local),
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

  /// Merged field by field rather than replacing the object, so the settings
  /// that never travel — theme, notifications, the backup folder — survive a
  /// pull from a device that has different ones.
  Future<SyncItem?> _applySettings(RemoteState state) async {
    final Map<String, Object?> f = state.fields;
    final AppSettings current = await _settings.load();

    final AppSettings merged = current.copyWith(
      semesterStart: _date(f['semesterStart']),
      semesterEnd: _date(f['semesterEnd']),
      targetPercent: _double(f['targetPercent']),
      defaultClassDurationMinutes: _int(f['defaultClassMinutes']),
      dayStartMinutes: _int(f['dayStartMinutes']),
      dayEndMinutes: _int(f['dayEndMinutes']),
      blockMinutes: _int(f['blockMinutes']),
      breakAfterBlock: _int(f['breakAfterBlock']),
      breakMinutes: _int(f['breakMinutes']),
      scheduleChangedAt: state.editedAt,
    );
    await _settings.save(merged);
    return SyncItem.settings(merged, changedAt: merged.scheduleChangedAt);
  }

  Future<SyncItem?> _applyCategory(RemoteState state, _Local local) async {
    final ClassCategory? existing = local.categoryByName[state.localKey];
    final ClassCategory category = ClassCategory(
      id: existing?.id,
      name: state.localKey,
      defaultDurationMinutes: _int(state.fields['defaultMinutes']) ??
          existing?.defaultDurationMinutes ??
          60,
      createdAt: state.editedAt ?? existing?.createdAt,
    );

    if (existing == null) {
      final int id = await _repository.insertCategory(category);
      local.categoryByName[state.localKey] = ClassCategory(
        id: id,
        name: category.name,
        defaultDurationMinutes: category.defaultDurationMinutes,
        createdAt: category.createdAt,
      );
    } else {
      await _repository.updateCategory(category);
      local.categoryByName[state.localKey] = category;
    }
    return SyncItem.category(category);
  }

  Future<SyncItem?> _applyRoom(RemoteState state, _Local local) async {
    final Room? existing = local.roomByName[state.localKey];
    final Room room = Room(
      id: existing?.id,
      name: state.localKey,
      position: _int(state.fields['position']) ?? existing?.position ?? 0,
    );

    if (existing == null) {
      final int id = await _repository.insertRoom(room);
      local.roomByName[state.localKey] =
          Room(id: id, name: room.name, position: room.position);
    } else {
      await _repository.updateRoom(room);
      local.roomByName[state.localKey] = room;
    }
    return SyncItem.room(room);
  }

  Future<SyncItem?> _applyTag(RemoteState state, _Local local) async {
    final Tag? existing = local.tagByName[state.localKey];
    final Tag tag = Tag(
      id: existing?.id,
      name: state.localKey,
      position: _int(state.fields['position']) ?? existing?.position ?? 0,
    );

    if (existing == null) {
      final int id = await _repository.insertTag(tag);
      local.tagByName[state.localKey] =
          Tag(id: id, name: tag.name, position: tag.position);
    } else {
      await _repository.updateTag(tag);
      local.tagByName[state.localKey] = tag;
    }
    return SyncItem.tag(tag);
  }

  /// The date is the key and the table already makes it unique, so a pulled
  /// holiday is replaced rather than updated — there is no other field that
  /// could have moved.
  Future<SyncItem?> _applyHoliday(RemoteState state, _Local local) async {
    final int? dateKey = int.tryParse(state.localKey);
    final String? name = state.fields['name'] as String?;
    if (dateKey == null || name == null) return null;

    final Holiday? existing = local.holidayByKey[state.localKey];
    if (existing?.id != null) {
      await _repository.deleteHoliday(existing!.id!);
    }
    final Holiday holiday = Holiday(date: Dates.fromKey(dateKey), name: name);
    final int id = await _repository.insertHoliday(holiday);
    local.holidayByKey[state.localKey] =
        Holiday(id: id, date: holiday.date, name: holiday.name);
    return SyncItem.holiday(holiday);
  }

  Future<SyncItem?> _applySubject(RemoteState state, _Local local) async {
    final Subject? existing = local.subjectByUuid[state.localKey];
    final Map<String, Object?> f = state.fields;
    final String? name = f['name'] as String?;
    if (name == null || name.isEmpty) return null;

    final String? categoryName = f['category'] as String?;
    final Subject subject = Subject(
      id: existing?.id,
      uuid: state.localKey,
      name: name,
      code: f['code'] as String?,
      teacher: f['teacher'] as String?,
      colorValue: _int(f['color']) ?? existing?.colorValue ?? 0xff607d8b,
      targetPercent: _double(f['targetPercent']),
      // Categories sync first, so a named one is already here unless the far
      // side never had it.
      categoryId:
          categoryName == null ? null : local.categoryByName[categoryName]?.id,
      // The row's own creation date survives a sync — only a subject arriving
      // for the first time has none of its own to keep.
      createdAt: existing?.createdAt ?? state.editedAt,
      updatedAt: state.editedAt,
      priorHeld: _int(f['priorHeld']) ?? 0,
      priorAttended: _int(f['priorAttended']) ?? 0,
      expectedTotal: _int(f['expectedTotal']),
    );

    if (existing == null) {
      final int id = await _repository.insertSubject(subject);
      local.subjectByUuid[state.localKey] = subject.copyWith(id: id);
    } else {
      await _repository.updateSubject(subject, touch: false);
      local.subjectByUuid[state.localKey] = subject;
    }
    return SyncItem.subject(subject, categoryName: categoryName);
  }

  Future<SyncItem?> _applySlot(RemoteState state, _Local local) async {
    final Map<String, Object?> f = state.fields;
    final String? subjectUuid = f['subject'] as String?;
    final Subject? subject =
        subjectUuid == null ? null : local.subjectByUuid[subjectUuid];
    final int? startDate = _int(f['startDate']);
    if (subject?.id == null || startDate == null) return null;

    final int? endDate = _int(f['endDate']);
    final ClassSlot? existing = local.slotByUuid[state.localKey];
    final ClassSlot slot = ClassSlot(
      id: existing?.id,
      uuid: state.localKey,
      subjectId: subject!.id!,
      weekday: _int(f['weekday']) ?? DateTime.monday,
      startMinutes: _int(f['startMinutes']) ?? 0,
      endMinutes: _int(f['endMinutes']) ?? 0,
      room: f['room'] as String?,
      weight: _int(f['weight']) ?? 1,
      startDate: Dates.fromKey(startDate),
      endDate: endDate == null ? null : Dates.fromKey(endDate),
    );

    if (existing == null) {
      final int id = await _repository.insertSlot(slot);
      local.slotByUuid[state.localKey] = slot.copyWith(id: id);
    } else {
      await _repository.updateSlot(slot);
      local.slotByUuid[state.localKey] = slot;
    }
    return SyncItem.slot(slot, subjectUuid!);
  }

  Future<SyncItem?> _applyExtraClass(RemoteState state, _Local local) async {
    final Map<String, Object?> f = state.fields;
    final String? subjectUuid = f['subject'] as String?;
    final Subject? subject =
        subjectUuid == null ? null : local.subjectByUuid[subjectUuid];
    final int? date = _int(f['date']);
    if (subject?.id == null || date == null) return null;

    final ExtraClass? existing = local.extraByUuid[state.localKey];
    final ExtraClass extra = ExtraClass(
      id: existing?.id,
      uuid: state.localKey,
      subjectId: subject!.id!,
      date: Dates.fromKey(date),
      startMinutes: _int(f['startMinutes']) ?? 0,
      endMinutes: _int(f['endMinutes']) ?? 0,
      room: f['room'] as String?,
      weight: _int(f['weight']) ?? 1,
      note: f['note'] as String?,
    );

    if (existing == null) {
      final int id = await _repository.insertExtraClass(extra);
      local.extraByUuid[state.localKey] = extra.copyWith(id: id);
    } else {
      await _repository.updateExtraClass(extra);
      local.extraByUuid[state.localKey] = extra;
    }
    return SyncItem.extraClass(extra, subjectUuid!);
  }

  Future<SyncItem?> _applyAttendance(RemoteState state, _Local local) async {
    final _MarkKey? key = _MarkKey.parse(state.localKey);
    final Subject? subject = key == null ? null : local.subjectByUuid[key.uuid];
    // A mark for a subject this device has never heard of. Subjects sync
    // first, so the only way here is a subject that failed to apply; the row
    // stays unlinked and the next run offers it again.
    if (key == null || subject?.id == null) return null;

    final AttendanceStatus? status =
        AttendanceStatus.fromName(state.fields['status'] as String?);
    if (status == null) return null;

    final String? tagName = state.fields['tag'] as String?;
    final AttendanceRecord record = AttendanceRecord(
      subjectId: subject!.id!,
      date: key.date,
      startMinutes: key.startMinutes,
      status: status,
      weight: _int(state.fields['weight']) ?? 1,
      tagId: tagName == null ? null : local.tagByName[tagName]?.id,
      note: state.fields['note'] as String?,
      markedAt: state.editedAt,
    );
    await _repository.setAttendance(record);
    return SyncItem.attendance(record, key.uuid, tagName: tagName);
  }

  Future<void> _deleteLocal(
    SyncKind kind,
    String localKey,
    _Local local,
  ) async {
    switch (kind) {
      // The row always exists, and clearing the semester dates because another
      // device stopped holding them is not a deletion anyone asked for.
      case SyncKind.settings:
        return;
      case SyncKind.category:
        final ClassCategory? category = local.categoryByName.remove(localKey);
        if (category?.id != null) {
          await _repository.deleteCategory(category!.id!);
        }
      case SyncKind.room:
        final Room? room = local.roomByName.remove(localKey);
        if (room?.id != null) await _repository.deleteRoom(room!.id!);
      case SyncKind.tag:
        final Tag? tag = local.tagByName.remove(localKey);
        if (tag?.id != null) await _repository.deleteTag(tag!.id!);
      case SyncKind.holiday:
        final Holiday? holiday = local.holidayByKey.remove(localKey);
        if (holiday?.id != null) {
          await _repository.deleteHoliday(holiday!.id!);
        }
      case SyncKind.subject:
        final Subject? subject = local.subjectByUuid.remove(localKey);
        if (subject?.id != null) await _repository.deleteSubject(subject!.id!);
      case SyncKind.slot:
        final ClassSlot? slot = local.slotByUuid.remove(localKey);
        if (slot?.id != null) await _repository.deleteSlot(slot!.id!);
      case SyncKind.extraClass:
        final ExtraClass? extra = local.extraByUuid.remove(localKey);
        if (extra?.id != null) await _repository.deleteExtraClass(extra!.id!);
      case SyncKind.attendance:
        final _MarkKey? key = _MarkKey.parse(localKey);
        final Subject? subject =
            key == null ? null : local.subjectByUuid[key.uuid];
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

    await _adoptSubjects(remote[SyncKind.subject]);

    // Re-read between the two: a class is recognised by its subject, so the
    // subjects have to have settled before anything under them is matched.
    final Map<int, String> subjectUuid = <int, String>{
      for (final Subject s in await _repository.getSubjects())
        if (s.id != null && s.uuid != null) s.id!: s.uuid!,
    };
    await _adoptClasses(remote[SyncKind.slot], remote[SyncKind.extraClass],
        subjectUuid);
  }

  Future<void> _adoptSubjects(List<RemoteState>? theirs) async {
    if (theirs == null || theirs.isEmpty) return;

    final List<Subject> rows = await _repository.getSubjects();
    final Set<String> held = _uuids(rows.map((Subject s) => s.uuid));
    final Set<String> known = _uuids(theirs.map((RemoteState r) => r.localKey));

    final List<Subject> unknown = <Subject>[
      for (final Subject s in rows)
        if (s.uuid == null || !known.contains(s.uuid)) s,
    ];
    if (unknown.isEmpty) return;

    final Map<int, String> adopted = matchByKey(
      unknown: <RowIdentity>[
        for (final Subject s in unknown) RowIdentity(key: subjectKey(s.code)),
      ],
      known: _adoptable(theirs, held,
          (RemoteState r) => subjectKey(r.fields['code'] as String?)),
    );

    for (final MapEntry<int, String> entry in adopted.entries) {
      // Not an edit, so it must not be stamped as one: an `updatedAt` of now
      // would have this side win a conflict it should lose.
      await _repository.updateSubject(
        unknown[entry.key].copyWith(uuid: entry.value),
        touch: false,
      );
    }
  }

  Future<void> _adoptClasses(
    List<RemoteState>? theirSlots,
    List<RemoteState>? theirExtras,
    Map<int, String> subjectUuid,
  ) async {
    if (theirSlots != null && theirSlots.isNotEmpty) {
      final List<ClassSlot> rows = await _repository.getSlots();
      final Set<String> held = _uuids(rows.map((ClassSlot s) => s.uuid));
      final Set<String> known =
          _uuids(theirSlots.map((RemoteState r) => r.localKey));
      final List<ClassSlot> unknown = <ClassSlot>[
        for (final ClassSlot s in rows)
          if (s.uuid == null || !known.contains(s.uuid)) s,
      ];

      final Map<int, String> adopted = matchByKey(
        unknown: <RowIdentity>[
          for (final ClassSlot s in unknown)
            RowIdentity(
              key: slotKey(subjectUuid[s.subjectId], s.weekday, s.startMinutes),
            ),
        ],
        known: _adoptable(
          theirSlots,
          held,
          (RemoteState r) => slotKey(
            r.fields['subject'] as String?,
            (r.fields['weekday'] as num?)?.toInt() ?? -1,
            (r.fields['startMinutes'] as num?)?.toInt() ?? -1,
          ),
        ),
      );

      for (final MapEntry<int, String> entry in adopted.entries) {
        await _repository
            .updateSlot(unknown[entry.key].copyWith(uuid: entry.value));
      }
    }

    if (theirExtras == null || theirExtras.isEmpty) return;

    final List<ExtraClass> rows = await _repository.getExtraClasses();
    final Set<String> held = _uuids(rows.map((ExtraClass e) => e.uuid));
    final Set<String> known =
        _uuids(theirExtras.map((RemoteState r) => r.localKey));
    final List<ExtraClass> unknown = <ExtraClass>[
      for (final ExtraClass e in rows)
        if (e.uuid == null || !known.contains(e.uuid)) e,
    ];

    final Map<int, String> adopted = matchByKey(
      unknown: <RowIdentity>[
        for (final ExtraClass e in unknown)
          RowIdentity(
            key: extraKey(
                subjectUuid[e.subjectId], Dates.keyOf(e.date), e.startMinutes),
          ),
      ],
      known: _adoptable(
        theirExtras,
        held,
        (RemoteState r) => extraKey(
          r.fields['subject'] as String?,
          (r.fields['date'] as num?)?.toInt() ?? -1,
          (r.fields['startMinutes'] as num?)?.toInt() ?? -1,
        ),
      ),
    );

    for (final MapEntry<int, String> entry in adopted.entries) {
      await _repository
          .updateExtraClass(unknown[entry.key].copyWith(uuid: entry.value));
    }
  }

  /// The account rows an identity can be taken from. A tombstone is none, and
  /// neither is a uuid this device already holds — that one belongs to another
  /// of its rows, and taking it would leave two on one identity.
  List<RowIdentity> _adoptable(
    List<RemoteState> theirs,
    Set<String> held,
    String? Function(RemoteState) key,
  ) =>
      <RowIdentity>[
        for (final RemoteState state in theirs)
          if (!state.deleted && !held.contains(state.localKey))
            RowIdentity(key: key(state), uuid: state.localKey),
      ];

  Set<String> _uuids(Iterable<String?> values) => <String>{
        for (final String? value in values)
          if (value != null) value,
      };

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
    return hasLocal && _remoteHasContent(remote) ? _Merge.review : _Merge.proceed;
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

/// Every lookup a pull needs to turn a far-side key back into a local row.
///
/// Mutable, and updated as rows are applied: a slot arriving in the same run
/// as the subject it names has to find it.
class _Local {
  _Local({
    required this.subjectByUuid,
    required this.categoryByName,
    required this.roomByName,
    required this.tagByName,
    required this.holidayByKey,
    required this.slotByUuid,
    required this.extraByUuid,
  });

  final Map<String, Subject> subjectByUuid;
  final Map<String, ClassCategory> categoryByName;
  final Map<String, Room> roomByName;
  final Map<String, Tag> tagByName;
  final Map<String, Holiday> holidayByKey;
  final Map<String, ClassSlot> slotByUuid;
  final Map<String, ExtraClass> extraByUuid;

  final Map<SyncKind, List<SyncItem>> items = <SyncKind, List<SyncItem>>{};
}

class _Tally {
  int pushed = 0;
  int pulled = 0;
  int archived = 0;
  int overwritten = 0;
  String? message;
  final List<SyncPull> review = <SyncPull>[];

  final Map<SyncKind, List<String>> pulledKeys = <SyncKind, List<String>>{};

  void pull(SyncKind kind, String localKey) {
    pulled++;
    pulledKeys.putIfAbsent(kind, () => <String>[]).add(localKey);
  }
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

/// A day key back to a date. Null stays null, so a semester end that has not
/// been set travels as "not set" rather than as an epoch.
DateTime? _date(Object? value) {
  final int? key = _int(value);
  return key == null ? null : Dates.fromKey(key);
}

double? _double(Object? value) => switch (value) {
      num v => v.toDouble(),
      String v => double.tryParse(v),
      _ => null,
    };
