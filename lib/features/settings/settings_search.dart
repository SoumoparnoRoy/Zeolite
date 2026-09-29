import 'settings_pages.dart';

/// Something a user might look for in Settings, and the menu row it lives
/// behind. [item] is null for the target, which is on the menu page itself.
class SettingsTopic {
  const SettingsTopic(this.title, this.item, [this.words = '']);

  final String title;
  final SettingsItem? item;

  /// Other words people use for it, so "semester" finds the term dates.
  final String words;
}

const List<SettingsTopic> settingsTopics = <SettingsTopic>[
  SettingsTopic('Minimum required', null, 'target percentage attendance goal'),
  SettingsTopic('Subjects', SettingsItem.subjects, 'courses colour target'),
  SettingsTopic(
    'Class categories',
    SettingsItem.categories,
    'lecture practical tutorial lab weight counts as',
  ),
  SettingsTopic('Default class length', SettingsItem.categories, 'duration'),
  SettingsTopic(
    'Apply to every class',
    SettingsItem.categories,
    'weights reweight',
  ),
  SettingsTopic('Term dates', SettingsItem.term, 'semester starts ends'),
  SettingsTopic(
    'Cancelled classes count as attended',
    SettingsItem.term,
    'counting',
  ),
  SettingsTopic('Holidays', SettingsItem.term, 'break vacation day off'),
  SettingsTopic(
    'Teaching day',
    SettingsItem.teachingDay,
    'blocks grid starts ends break lunch periods',
  ),
  SettingsTopic('Rooms', SettingsItem.roomsAndTags, 'classroom venue'),
  SettingsTopic('Tags', SettingsItem.roomsAndTags, 'proxy online makeup'),
  SettingsTopic(
    'Import timetable',
    SettingsItem.importTimetable,
    'paste photo image screenshot picture',
  ),
  SettingsTopic(
    'Import a class log',
    SettingsItem.importClassLog,
    'csv spreadsheet notion export history',
  ),
  SettingsTopic('Theme', SettingsItem.appearance, 'dark light mode system'),
  SettingsTopic('Accent colour', SettingsItem.appearance, 'color tint'),
  SettingsTopic('Launch animation', SettingsItem.appearance, 'intro opening'),
  SettingsTopic('Launcher icon', SettingsItem.appearance, 'app icon'),
  SettingsTopic(
    '24-hour time',
    SettingsItem.appearance,
    'clock 12-hour format am pm',
  ),
  SettingsTopic(
    'All notifications',
    SettingsItem.notifications,
    'alerts reminders',
  ),
  SettingsTopic(
    'Before each class',
    SettingsItem.notifications,
    'reminder notification minutes',
  ),
  SettingsTopic(
    'When each class ends',
    SettingsItem.notifications,
    'notification mark',
  ),
  SettingsTopic(
    'Evening reminder',
    SettingsItem.notifications,
    'notification unmarked',
  ),
  SettingsTopic(
    'Attendance alerts',
    SettingsItem.notifications,
    'warning danger limit notification',
  ),
  SettingsTopic('Exact timing', SettingsItem.notifications, 'alarm late'),
  SettingsTopic(
    'Account',
    SettingsItem.account,
    'sign in sign out log in email backup sync cloud',
  ),
  SettingsTopic('Delete my account', SettingsItem.account, 'remove'),
  SettingsTopic('Notion sync', SettingsItem.notion, 'connect workspace'),
  SettingsTopic('Import from your table', SettingsItem.notion, 'notion'),
  SettingsTopic('Take the latest template', SettingsItem.notion, 'notion'),
  SettingsTopic('Rewrite every row', SettingsItem.notion, 'notion resync'),
  SettingsTopic('Export backup', SettingsItem.yourData, 'save json file'),
  SettingsTopic('Import backup', SettingsItem.yourData, 'restore file'),
  SettingsTopic('Automatic backup', SettingsItem.yourData, 'daily'),
  SettingsTopic('Backup folder', SettingsItem.yourData, 'location'),
  SettingsTopic(
    'Match classes with no time',
    SettingsItem.yourData,
    'untimed',
  ),
  SettingsTopic(
    'Reset everything',
    SettingsItem.yourData,
    'delete erase wipe clear data',
  ),
  SettingsTopic('Privacy Policy', SettingsItem.privacy, 'data legal'),
  SettingsTopic('Terms of Use', SettingsItem.terms, 'legal conditions'),
  SettingsTopic(
    'Open-source licences',
    SettingsItem.licences,
    'licenses acknowledgements credits attribution fonts',
  ),
];

/// Every word typed has to start a word somewhere in the topic, so "back"
/// finds the backups but "ckup" finds nothing. Title matches come first.
List<SettingsTopic> searchSettings(String query) {
  final List<String> typed = _words(query);
  if (typed.isEmpty) return const <SettingsTopic>[];

  final List<(SettingsTopic, bool)> hits = <(SettingsTopic, bool)>[];
  for (final SettingsTopic topic in settingsTopics) {
    final List<String> title = _words(topic.title);
    final List<String> all = <String>[
      ...title,
      ..._words(topic.words),
      ..._words(topic.item?.title ?? ''),
    ];
    bool starts(List<String> pool, String w) =>
        pool.any((String p) => p.startsWith(w));
    if (typed.every((String w) => starts(all, w))) {
      hits.add((topic, typed.every((String w) => starts(title, w))));
    }
  }
  return <SettingsTopic>[
    for (final (SettingsTopic, bool) h in hits) if (h.$2) h.$1,
    for (final (SettingsTopic, bool) h in hits) if (!h.$2) h.$1,
  ];
}

List<String> _words(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((String w) => w.isNotEmpty)
    .toList();
