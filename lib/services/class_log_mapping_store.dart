import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/class_log.dart';

/// Remembers how a class log was read, keyed by its headers, so a later file
/// laid out the same way needs no questions.
///
/// Kept on this device only: it describes a file somebody picked here, and
/// a guess that is wrong costs nothing worse than being asked again.
class ClassLogMappingStore {
  ClassLogMappingStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  static const String _prefix = 'classlog.mapping.';

  Future<ClassLogMapping?> load(ClassLogTable table) async {
    try {
      final String? raw = await _prefs.getString('$_prefix${table.layout}');
      return raw == null ? null : ClassLogMapping.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<void> save(ClassLogTable table, ClassLogMapping mapping) =>
      _prefs.setString(
        '$_prefix${table.layout}',
        jsonEncode(mapping.toJson()),
      );
}
