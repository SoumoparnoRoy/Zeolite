import 'package:zeolite/domain/sync/sync_target.dart';

/// A target that keeps its pages in a map, so everything above [SyncTarget]
/// can be tested with no HTTP anywhere near it.
class FakeSyncTarget implements SyncTarget {
  FakeSyncTarget({this.pages = const <String, String>{}});

  @override
  String get id => 'fake';

  @override
  bool trustsPulls = false;

  /// Page id to the hash the target would report for it.
  Map<String, String> pages;

  SyncFailure? failNext;

  /// Null makes [fetch] report that it could not read the far side.
  List<RemoteState>? remote = <RemoteState>[];

  final List<String> calls = <String>[];

  int _nextId = 1;

  @override
  Future<List<RemoteState>?> fetch(SyncKind kind) async {
    calls.add('fetch');
    return remote
        ?.where((RemoteState state) => state.kind == kind)
        .toList(growable: false);
  }

  @override
  Future<SyncOutcome> create(SyncItem item) async {
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
