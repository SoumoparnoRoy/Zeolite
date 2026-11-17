import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/features/settings/help_topics.dart';
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

  test('Help and FAQ, and each of its questions, can be found', () {
    // The questions follow, since they live on that screen.
    expect(titles('faq').first, 'Help and FAQ');
    expect(searchSettings('faq').first.helpQuestion, isNull);
    final List<String> ids =
        helpQuestions.map((HelpQuestion q) => q.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'ids must be unique');
    for (final HelpQuestion q in helpQuestions) {
      final SettingsTopic first = searchSettings(q.question).first;
      expect(first.item, SettingsItem.help, reason: q.question);
      expect(first.helpQuestion, q.id, reason: q.question);
    }
  });

  test('words match from their start only, and blank finds nothing', () {
    expect(titles('ckup'), isEmpty);
    expect(titles('   '), isEmpty);
  });
}
