import 'package:shared_preferences/shared_preferences.dart';

/// The subjects a wiped install left keys under on one target, as the first
/// run there found them, so rows that run could not settle stay claimable.
class SyncStrayStore {
  SyncStrayStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  static const String _prefix = 'sync.strays.';

  Future<Set<String>> load(String targetId) async {
    try {
      return (await _prefs.getStringList('$_prefix$targetId'))?.toSet() ??
          <String>{};
    } on Object {
      return <String>{};
    }
  }

  Future<void> save(String targetId, Set<String> subjects) =>
      _prefs.setStringList('$_prefix$targetId', subjects.toList());
}
