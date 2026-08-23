import '../data/db/zeolite_repository.dart';

/// Holds the one snapshot that can currently be undone.
///
/// Only one, because a snapshot is the *whole* database: restoring an older one
/// would also throw away everything done since. So it is dropped as soon as any
/// other mutation happens, and the offer goes with it.
class UndoStore {
  DatabaseSnapshot? _snapshot;
  int? _token;
  int _nextToken = 1;

  int? get pendingToken => _token;

  int arm(DatabaseSnapshot snapshot) {
    _snapshot = snapshot;
    return _token = _nextToken++;
  }

  void drop() {
    _snapshot = null;
    _token = null;
  }

  /// The snapshot behind [token], or null if it is no longer the one on offer.
  ///
  /// Delete two subjects quickly and the first snackbar can still be on screen
  /// when the second replaces the snapshot — without the token its Undo would
  /// restore the wrong one.
  DatabaseSnapshot? take(int token) {
    if (token != _token) return null;
    final DatabaseSnapshot? snapshot = _snapshot;
    drop();
    return snapshot;
  }
}
