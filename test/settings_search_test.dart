import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/features/settings/settings_pages.dart';
import 'package:zeolite/features/settings/settings_search.dart';

void main() {
  List<String> titles(String query) =>
      searchSettings(query).map((SettingsTopic t) => t.title).toList();

  test('every menu row can be found by its own name', () {
    for (final SettingsItem item in SettingsItem.values) {
      expect(
        searchSettings(item.title).map((SettingsTopic t) => t.item),
        contains(item),
        reason: item.title,
      );
    }
  });

  test('other words for a setting find it, title matches first', () {
    expect(titles('semester'), <String>['Term dates']);
    expect(titles('dark'), <String>['Theme']);
    expect(titles('backup').take(3), <String>[
      'Export backup',
      'Import backup',
      'Automatic backup',
    ]);
  });

  test('words match from their start only, and blank finds nothing', () {
    expect(titles('ckup'), isEmpty);
    expect(titles('   '), isEmpty);
  });
}
