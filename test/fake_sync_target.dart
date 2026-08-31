import 'dart:async';

import 'package:zeolite/domain/sync/sync_target.dart';

/// A target that keeps its pages in a map, so everything above [SyncTarget]
/// can be tested with no HTTP anywhere near it.
class FakeSyncTarget implements SyncTarget {
  FakeSyncTarget({this.pages = const <String, String>{}});

  @override
  String get id => 'fake';

  @override
  bool trustsPulls = false;

  /// Mutable so a test can model either kind of far side.
  @override
  bool recreatesMissingRows = false;

  /// Mutable so a test can shrink it to the one kind a Notion-shaped target
  /// keeps.
  @override
  Set<SyncKind> kinds = SyncKind.values.toSet();

  /// Page id to the hash the target would report for it.
  Map<String, String> pages;

  SyncFailure? failNext;

  /// Null makes [fetch] report that it could not read the far side.
  List<RemoteState>? remote = <RemoteState>[];

  final List<String> calls = <String>[];

  /// Blocks the start of every run, so two can be put in flight at once.
  Future<void>? hold;

  /// Blocks at the first write instead — past the local read, which is the
  /// only point a change can be made that the running one cannot see.
  Future<void>? holdCreate;

  /// So a test can act at that moment rather than guess at a delay.
  final Completer<void> reachedCreate = Completer<void>();

  int _nextId = 1;

  @override
  Future<List<RemoteState>?> fetch(SyncKind kind) async {
    if (hold != null) await hold;
    calls.add('fetch');
    return remote
        ?.where((RemoteState state) => state.kind == kind)
        .toList(growable: false);
  }

  @override
  Future<SyncOutcome> create(SyncItem item) async {
    if (!reachedCreate.isCompleted) reachedCreate.complete();
    if (holdCreate != null) await holdCreate;
    calls.add('create ${item.localKey}');
    final SyncOutcome? failure = _takeFailure();
    if (failure != null) return failure;
    final String remoteId = 'page-${_nextId++}';
    pages = <String, String>{...pages, remoteId: item.hash};
    return SyncOutcome.done(remoteId: remoteId, remoteHash: item.hash);
  }

  @override
  Future<SyncOutcome> update(SyncItem item, String remoteId) async {
    calls.add('update $remoteId');
    final SyncOutcome? failure = _takeFailure();
    if (failure != null) return failure;
    pages = <String, String>{...pages, remoteId: item.hash};
    return SyncOutcome.done(remoteId: remoteId, remoteHash: item.hash);
  }

  @override
  Future<SyncOutcome> archive(SyncKind kind, String remoteId) async {
    calls.add('archive $remoteId');
    final SyncOutcome? failure = _takeFailure();
    if (failure != null) return failure;
    pages = <String, String>{...pages}..remove(remoteId);
    return SyncOutcome.done(remoteId: remoteId, remoteHash: '');
  }

  SyncOutcome? _takeFailure() {
    final SyncFailure? failure = failNext;
    if (failure == null) return null;
    failNext = null;
    return SyncOutcome.failed(failure);
  }
}
