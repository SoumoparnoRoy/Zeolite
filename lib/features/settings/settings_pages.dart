import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/holiday_runs.dart';
import '../../services/notification_service.dart';
import '../../state/auth_providers.dart';
import '../../state/notion_providers.dart';
import '../../state/providers.dart';
import '../../widgets/gradient_header.dart';
import '../launch/welcome_screen.dart';
import '../subjects/subjects_screen.dart';
import '../timetable/import_screen.dart';

import 'account_screen.dart';
import 'appearance_section.dart';
import 'data_section.dart';
import 'licences_screen.dart';
import 'notifications_section.dart';
import 'settings_rows.dart';
import 'subjects_section.dart';
import 'sync_section.dart';
import 'term_section.dart';
import 'timetable_layout_section.dart';

enum SettingsGroup {
  classes('Your classes'),
  files('Add from a file'),
  app('App'),
  sync('Backup and sync'),
  about('About');

  const SettingsGroup(this.label);

  final String label;
}

/// One row of the Settings menu, in the order the menu draws them.
enum SettingsItem {
  subjects('Subjects', Icons.menu_book_outlined, SettingsGroup.classes),
  categories(
    'Class categories',
    Icons.category_outlined,
    SettingsGroup.classes,
  ),
  term('Term', Icons.date_range_outlined, SettingsGroup.classes),
  teachingDay(
    'Teaching day',
    Icons.view_week_outlined,
    SettingsGroup.classes,
  ),
  roomsAndTags('Rooms and tags', Icons.sell_outlined, SettingsGroup.classes),
  importTimetable(
    'Import timetable',
    Icons.playlist_add_rounded,
    SettingsGroup.files,
  ),
  importClassLog(
    'Import a class log',
    Icons.history_rounded,
    SettingsGroup.files,
  ),
  appearance('Appearance', Icons.palette_outlined, SettingsGroup.app),
  notifications(
    'Notifications',
    Icons.notifications_outlined,
    SettingsGroup.app,
  ),
  account('Account', Icons.cloud_outlined, SettingsGroup.sync),
  notion('Notion', Icons.sync_alt_rounded, SettingsGroup.sync),
  yourData('Your data', Icons.storage_rounded, SettingsGroup.sync),
  privacy('Privacy Policy', Icons.privacy_tip_outlined, SettingsGroup.about),
  terms('Terms of Use', Icons.gavel_rounded, SettingsGroup.about),
  licences(
    'Open-source licences',
    Icons.description_outlined,
    SettingsGroup.about,
  );

  const SettingsItem(this.title, this.icon, this.group);

  final String title;
  final IconData icon;
  final SettingsGroup group;

  /// Opens outside the app rather than as a page.
  bool get isLink => this == privacy || this == terms;

  Future<void> open(BuildContext context, WidgetRef ref) async {
    switch (this) {
      case importClassLog:
        return importClassLogFile(context, ref);
      case privacy:
        unawaited(launchUrl(WelcomeCopy.privacyUrl,
            mode: LaunchMode.inAppBrowserView));
        return;
      case terms:
        unawaited(
            launchUrl(WelcomeCopy.termsUrl, mode: LaunchMode.inAppBrowserView));
        return;
      default:
        break;
    }
    if (this == notion) {
      // Wakes the host while the user is still reading the page, since the
      // next tap is usually the connect screen.
      unawaited(ref.read(notionAuthClientProvider).health());
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: _routeName),
        builder: (BuildContext context) => _page,
      ),
    );
  }

  /// The first three keep the names they had before the menu existed.
  String get _routeName => switch (this) {
        subjects => 'subjects',
        importTimetable => 'import_timetable',
        account => 'account',
        _ => 'settings_$name',
      };

  Widget get _page => switch (this) {
        subjects => const SubjectsScreen(),
        importTimetable => const ImportTimetableScreen(),
        account => const AccountScreen(),
        categories => _SettingsPage(this, const <Widget>[CategoriesSection()]),
        term => _SettingsPage(this, const <Widget>[
            TermSection(),
            CountingSection(),
            HolidaysSection(),
          ]),
        teachingDay => _SettingsPage(this, const <Widget>[DayGridSection()]),
        roomsAndTags => _SettingsPage(this, const <Widget>[
            RoomsSection(),
            TagsSection(),
          ]),
        appearance => _SettingsPage(this, const <Widget>[
            AppearanceSection(),
            DisplaySection(),
          ]),
        notifications =>
          _SettingsPage(this, const <Widget>[NotificationsSection()]),
        notion => _SettingsPage(this, const <Widget>[NotionSection()]),
        yourData => _SettingsPage(this, const <Widget>[DataSection()]),
        // The fonts' OFL texts are registered in `main.dart`; this is the only
        // place a user can read them.
        licences => const LicencesScreen(),
        importClassLog ||
        privacy ||
        terms =>
          throw StateError('$name does not open a page'),
      };
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage(this.item, this.sections);

  final SettingsItem item;
  final List<Widget> sections;

  @override
  Widget build(BuildContext context) {
    return PushScaffold(
      title: item.title,
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          sliver: SliverList.list(
            children: <Widget>[
              for (int i = 0; i < sections.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: AppSpacing.xl),
                sections[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A menu row whose second line says what is set, so most visits to Settings
/// end without opening anything.
class SettingsItemRow extends ConsumerWidget {
  const SettingsItemRow(this.item, {super.key});

  final SettingsItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final TimetableData? timetable = ref.watch(timetableProvider).value;

    final String value = switch (item) {
      SettingsItem.subjects => _subjectsLine(timetable),
      SettingsItem.categories => (timetable?.categories ?? const [])
          .map((c) => c.name)
          .join(', ')
          .ifEmpty('None yet'),
      SettingsItem.term => _termLine(settings, timetable),
      SettingsItem.teachingDay => settings.dayGrid.isConfigured
          ? '${Clock.format(settings.dayStartMinutes, use24Hour: settings.use24HourTime)} – '
              '${Clock.format(settings.dayEndMinutes, use24Hour: settings.use24HourTime)} · '
              '${Clock.formatDuration(settings.blockMinutes)} blocks'
          : 'Not divided into blocks',
      SettingsItem.roomsAndTags => _roomsLine(timetable),
      SettingsItem.importTimetable => 'Paste the whole week, or read a photo',
      SettingsItem.importClassLog =>
        'A spreadsheet or Notion export of what you attended',
      SettingsItem.appearance =>
        '${settings.themeMode.label} · ${settings.accentColour.label}',
      SettingsItem.notifications => _notificationsLine(
          settings,
          ref.watch(trayAccessProvider).value ?? TrayAccess.open,
        ),
      SettingsItem.account => ref.watch(signedInUserProvider).value?.email ??
          'Not signed in — nothing is backed up',
      SettingsItem.notion =>
        ref.watch(notionConnectionProvider).value?.workspaceName ??
            'Not connected',
      SettingsItem.yourData => settings.autoBackupEnabled
          ? 'Backed up automatically once a day'
          : 'Automatic backup is off',
      SettingsItem.privacy => 'What leaves your device, and when',
      SettingsItem.terms => 'The rules for using Zeolite',
      SettingsItem.licences => 'The packages and fonts Zeolite is built on',
    };

    return SettingsRow(
      icon: item.icon,
      title: item.title,
      value: value,
      // The one state on the menu that is stopping something from working.
      danger: item == SettingsItem.notifications && value == _blocked,
      onTap: () => item.open(context, ref),
      trailing: item.isLink
          ? Icon(
              Icons.open_in_new_rounded,
              size: 16,
              color: context.palette.textFaint,
            )
          : null,
    );
  }

  static const String _blocked = 'Blocked in Android settings';

  static String _notificationsLine(AppSettings settings, TrayAccess tray) {
    if (!settings.notificationsEnabled) return 'Off';
    if (!tray.appAllowed) return _blocked;
    final int on = <bool>[
      settings.notifyBeforeClass,
      settings.notifyAtClassEnd,
      settings.notifyEveningReminder,
      settings.notifyAttendanceDanger,
    ].where((bool b) => b).length;
    return '$on of 4 turned on';
  }

  static String _subjectsLine(TimetableData? timetable) {
    final int subjects = timetable?.subjects.length ?? 0;
    if (subjects == 0) return 'None yet — add your first';
    final int classes =
        (timetable?.slots.length ?? 0) + (timetable?.extras.length ?? 0);
    return '${Words.plural(subjects, 'subject')} · '
        '${Words.plural(classes, 'class', 'classes')}';
  }

  static String _roomsLine(TimetableData? timetable) {
    final int rooms = timetable?.rooms.length ?? 0;
    final int tags = timetable?.tags.length ?? 0;
    if (rooms == 0 && tags == 0) return 'None yet';
    return '${Words.plural(rooms, 'room')} · ${Words.plural(tags, 'tag')}';
  }

  /// The year is said once, unless the term straddles two.
  static String _termStart(DateTime start, DateTime end) =>
      start.year == end.year
          ? '${start.day} ${kMonthNamesShort[start.month - 1]}'
          : Dates.formatFull(start);

  static String _termLine(AppSettings settings, TimetableData? timetable) {
    final DateTime? start = settings.termStart;
    final DateTime? end = settings.termEnd;
    final int breaks = buildHolidayRuns(timetable?.holidays ?? const []).length;
    return <String>[
      if (start == null || end == null)
        'Dates not set'
      else
        '${_termStart(start, end)} – ${Dates.formatFull(end)}',
      if (breaks > 0) Words.plural(breaks, 'holiday'),
    ].join(' · ');
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
