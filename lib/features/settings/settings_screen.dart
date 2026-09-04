import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../core/time_picker.dart';
import '../../data/models/class_category.dart';
import '../../data/models/holiday.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/class_weight.dart';
import '../../domain/holiday_runs.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../domain/notion_export.dart';
import '../../services/backup_folder.dart';
import '../../services/backup_service.dart';
import '../../services/launcher_icon_service.dart';
import '../../services/notification_service.dart';
import '../../services/notion/notion_connection_store.dart';
import '../../services/notion/notion_database_reader.dart';
import '../../state/notion_providers.dart';
import 'notion_template_migration.dart';
import '../../state/providers.dart';
import '../../state/auth_providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/class_editor_sheets.dart';
import '../subjects/notion_import_screen.dart';
import 'account_screen.dart';
import '../../domain/sync/sync_status.dart';
import '../../domain/sync/sync_target.dart';
import '../../services/sync/sync_coordinator.dart';
import '../../state/notion_sync_providers.dart';
import 'sync_status_line.dart';
import 'notion_connect_screen.dart';
import '../../domain/sync/sync_plan.dart';
import 'notion_review_screen.dart';
import 'notion_mapping_screen.dart';
import '../timetable/import_screen.dart';
import '../subjects/subjects_screen.dart';
import 'timetable_layout_section.dart';

/// Semester setup, attendance target, notifications, holidays and backup.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final TimetableData? timetable = ref.watch(timetableProvider).value;
    final List<Holiday> holidays = timetable?.holidays ?? <Holiday>[];
    final List<HolidayRun> runs = buildHolidayRuns(holidays);
    final bool folderUsable =
        ref.watch(backupFolderUsableProvider).value ?? false;
    final bool exactAlarms = ref.watch(exactAlarmsProvider).value ?? true;
    final List<ClassCategory> categories =
        timetable?.categories ?? <ClassCategory>[];
    final List<Subject> subjects = timetable?.subjects ?? <Subject>[];
    final int classCount =
        (timetable?.slots.length ?? 0) + (timetable?.extras.length ?? 0);
    final SettingsController controller = ref.read(settingsProvider.notifier);

    return GradientScaffold(
      headerGap: 22,
      header: _TargetHeader(
        target: settings.targetPercent,
        onChanged: controller.setTarget,
      ),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          sliver: SliverList.list(
            children: <Widget>[
              const SectionHeader('Term'),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    _Row(
                      icon: Icons.play_circle_outline_rounded,
                      title: 'Starts',
                      value: settings.semesterStart == null
                          ? 'Not set'
                          : Dates.formatFull(settings.semesterStart!),
                      onTap: () => _pickSemesterDate(
                        context,
                        controller,
                        settings,
                        isStart: true,
                      ),
                    ),
                    const Divider(indent: 58),
                    _Row(
                      icon: Icons.stop_circle_outlined,
                      title: 'Ends',
                      value: settings.semesterEnd == null
                          ? 'Not set'
                          : Dates.formatFull(settings.semesterEnd!),
                      onTap: () => _pickSemesterDate(
                        context,
                        controller,
                        settings,
                        isStart: false,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              const _Hint(
                'Recurring classes only appear between these dates, and the '
                '"classes left" figures are counted up to the end date.',
              ),
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Subjects'),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: _Row(
                  icon: Icons.menu_book_outlined,
                  title: 'Manage subjects',
                  value: subjects.isEmpty
                      ? 'None yet — add your first'
                      : '${subjects.length} '
                          '${subjects.length == 1 ? 'subject' : 'subjects'} · '
                          '$classCount ${classCount == 1 ? 'class' : 'classes'}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: 'subjects'),
                      builder: (BuildContext context) => const SubjectsScreen(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: _Row(
                  icon: Icons.playlist_add_rounded,
                  title: 'Import timetable',
                  value: 'Paste the whole week at once',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: 'import_timetable'),
                      builder: (BuildContext context) =>
                          const ImportTimetableScreen(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: _Row(
                  icon: Icons.history_rounded,
                  title: 'Import a class log',
                  value: 'A Notion export of what you have attended',
                  onTap: () => _importNotionLog(context, ref),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              const _Hint(
                'Add courses, change their colour or attendance target, and '
                'delete ones you have dropped.',
              ),
              const SizedBox(height: AppSpacing.xl),
              const DayGridSection(),
              const SizedBox(height: AppSpacing.xl),
              const RoomsSection(),
              const SizedBox(height: AppSpacing.xl),
              const TagsSection(),
              const SizedBox(height: AppSpacing.xl),
              SectionHeader(
                'Class categories',
                trailing: TextButton.icon(
                  onPressed: () => showCategoryEditor(context, ref),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add'),
                ),
              ),
              if (categories.isEmpty)
                const SurfaceCard(
                  child: _Hint(
                    'No categories yet. Create one — Lab, Theory, Tutorial — '
                    'give it a default length and say what one of its classes '
                    'counts as, then put your subjects in it.',
                  ),
                )
              else
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < categories.length; i++) ...<Widget>[
                        if (i > 0) const Divider(indent: 58),
                        _Row(
                          icon: Icons.category_outlined,
                          title: categories[i].name,
                          value: _categoryLine(
                            categories[i],
                            timetable?.subjects ?? const <Subject>[],
                          ),
                          onTap: () => showCategoryEditor(
                            context,
                            ref,
                            category: categories[i],
                          ),
                          trailing: IconButton(
                            onPressed: () =>
                                _deleteCategory(context, ref, categories[i]),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            color: context.palette.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              if (categories.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      OutlinedButton(
                        onPressed: () => _applyWeights(context, ref),
                        child: const Text('Apply to every class'),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      const _Hint(
                        'Classes and marks keep whatever they were worth when '
                        'you made them. This rewrites them all from the '
                        'categories above, and can be undone.',
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            'Default class length',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          Clock.formatDuration(
                            settings.defaultClassDurationMinutes,
                          ),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: context.palette.accent,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: settings.defaultClassDurationMinutes
                          .toDouble()
                          .clamp(15, 300),
                      min: 15,
                      max: 300,
                      divisions: 57,
                      label: Clock.formatDuration(
                        settings.defaultClassDurationMinutes,
                      ),
                      onChanged: (double value) => controller.save(
                        settings.copyWith(
                          defaultClassDurationMinutes: (value / 5).round() * 5,
                        ),
                      ),
                    ),
                    const _Hint(
                      'Used for subjects that are not in a category. Setting a '
                      'class start time fills the end time in from this.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Appearance'),
              SurfaceCard(
                child: _SegmentedRow(
                  count: AppThemeMode.values.length,
                  itemBuilder: (BuildContext context, int i) => _ThemeOption(
                    mode: AppThemeMode.values[i],
                    selected: settings.themeMode == AppThemeMode.values[i],
                    onTap: () => controller.save(
                      settings.copyWith(themeMode: AppThemeMode.values[i]),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _Hint(
                settings.themeMode == AppThemeMode.system
                    ? 'Follows your device setting, switching automatically when '
                        'it does.'
                    : 'Always ${settings.themeMode.label.toLowerCase()}, whatever '
                        'your device is set to.',
              ),
              const SizedBox(height: AppSpacing.md),
              SurfaceCard(
                child: _SegmentedRow(
                  count: AccentColour.values.length,
                  phoneColumns: 4,
                  itemBuilder: (BuildContext context, int i) => _AccentOption(
                    accent: AccentColour.values[i],
                    selected: settings.accentColour == AccentColour.values[i],
                    onTap: () => controller.save(
                      settings.copyWith(accentColour: AccentColour.values[i]),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _Hint('${settings.accentColour.label} tints the headers, the '
                  'buttons and every highlight. It stays on this device.'),
              const SizedBox(height: AppSpacing.md),
              SurfaceCard(
                child: _SegmentedRow(
                  count: LaunchAnimation.values.length,
                  itemBuilder: (BuildContext context, int i) => _LaunchOption(
                    animation: LaunchAnimation.values[i],
                    selected:
                        settings.launchAnimation == LaunchAnimation.values[i],
                    onTap: () => controller.save(
                      settings.copyWith(
                        launchAnimation: LaunchAnimation.values[i],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              // Not a switch reading "Skip launch animation": it skips
              // nothing, and a control that lies about what it does is worse
              // than a longer label.
              const _Hint('The launch animation. Short plays the wordmark '
                  'only, about a second.'),
              const SizedBox(height: AppSpacing.sm),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: _Row(
                  icon: Icons.apps_rounded,
                  title: 'Launcher icon',
                  value: ref.watch(launcherIconProvider).value?.label ??
                      LauncherIcon.standard.label,
                  onTap: () => _pickLauncherIcon(context, ref),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Notifications'),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    _SwitchRow(
                      icon: settings.notificationsEnabled
                          ? Icons.notifications_outlined
                          : Icons.notifications_off_outlined,
                      title: 'All notifications',
                      subtitle: settings.notificationsEnabled
                          ? 'Individual types can be turned off below'
                          : 'Nothing is sent to your notification tray',
                      value: settings.notificationsEnabled,
                      onChanged: (bool v) async {
                        if (v) {
                          await NotificationService.instance
                              .requestPermissions();
                        }
                        await controller
                            .save(settings.copyWith(notificationsEnabled: v));
                        await ref.read(actionsProvider).reloadAfterImport();
                      },
                    ),
                    const Divider(indent: 58),
                    _SwitchRow(
                      icon: Icons.chat_bubble_outline,
                      title: 'Show alerts in the app',
                      subtitle: settings.showDangerInApp
                          ? 'Attendance warnings appear here instead'
                          : 'Used when attendance alerts are switched off',
                      value: settings.inAppAlerts,
                      onChanged: (bool v) async {
                        await controller
                            .save(settings.copyWith(inAppAlerts: v));
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Opacity(
                // The per-type rows stay readable but inert while the master
                // switch is off, so it is obvious why they do nothing.
                opacity: settings.notificationsEnabled ? 1 : 0.4,
                child: IgnorePointer(
                  ignoring: !settings.notificationsEnabled,
                  child: SurfaceCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        _SwitchRow(
                          icon: Icons.notifications_active_outlined,
                          title: 'Before each class',
                          subtitle:
                              '${settings.notifyLeadMinutes} minutes before it starts',
                          value: settings.notifyBeforeClass,
                          onChanged: (bool v) async {
                            if (v) {
                              await NotificationService.instance
                                  .requestPermissions();
                            }
                            await controller
                                .save(settings.copyWith(notifyBeforeClass: v));
                            await ref.read(actionsProvider).reloadAfterImport();
                          },
                          onTapSubtitle: settings.notifyBeforeClass
                              ? () => _pickLeadTime(
                                  context, controller, settings, ref)
                              : null,
                        ),
                        if (settings.classRemindersActive) ...<Widget>[
                          const Divider(indent: 58),
                          _Row(
                            icon: Icons.timer_outlined,
                            title: 'Exact timing',
                            value: exactAlarms
                                ? 'Reminders arrive on the minute'
                                : 'Off — a reminder can be a few minutes late',
                            onTap: () => _requestExactAlarms(context, ref),
                          ),
                        ],
                        const Divider(indent: 58),
                        _SwitchRow(
                          icon: Icons.edit_calendar_outlined,
                          title: 'Evening reminder',
                          subtitle:
                              'Mark unmarked classes at ${Clock.format(settings.eveningReminderMinutes, use24Hour: settings.use24HourTime)}',
                          value: settings.notifyEveningReminder,
                          onChanged: (bool v) async {
                            if (v) {
                              await NotificationService.instance
                                  .requestPermissions();
                            }
                            await controller.save(
                                settings.copyWith(notifyEveningReminder: v));
                            await ref.read(actionsProvider).reloadAfterImport();
                          },
                          onTapSubtitle: settings.notifyEveningReminder
                              ? () => _pickEveningTime(
                                  context, controller, settings, ref)
                              : null,
                        ),
                        const Divider(indent: 58),
                        _SwitchRow(
                          icon: Icons.warning_amber_rounded,
                          title: 'Attendance alerts',
                          subtitle: settings.showDangerInApp
                              ? 'Off — shown in the app instead'
                              : 'Warn me when a subject nears the limit',
                          value: settings.notifyAttendanceDanger,
                          onChanged: (bool v) async {
                            if (v) {
                              await NotificationService.instance
                                  .requestPermissions();
                            }
                            await controller.save(
                                settings.copyWith(notifyAttendanceDanger: v));
                            await ref.read(actionsProvider).reloadAfterImport();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              SectionHeader(
                'Holidays',
                trailing: TextButton.icon(
                  onPressed: () => _addHoliday(context, ref),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add'),
                ),
              ),
              if (holidays.isEmpty)
                const SurfaceCard(
                  child: _Hint(
                    'No holidays yet. Add days when classes do not run — they '
                    'are skipped everywhere and never count against you.',
                  ),
                )
              else
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < runs.length; i++) ...<Widget>[
                        if (i > 0) const Divider(indent: 58),
                        _Row(
                          icon: Icons.celebration_outlined,
                          title: runs[i].name,
                          value: runs[i].isSingleDay
                              ? runs[i].dateLabel
                              : '${runs[i].dateLabel} · ${runs[i].lengthLabel}',
                          trailing: IconButton(
                            onPressed: () =>
                                _deleteHolidayRun(context, ref, runs[i]),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            color: context.palette.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Display'),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: _SwitchRow(
                  icon: Icons.schedule_rounded,
                  title: '24-hour time',
                  subtitle: settings.use24HourTime ? '14:30' : '2:30 PM',
                  value: settings.use24HourTime,
                  onChanged: (bool v) =>
                      controller.save(settings.copyWith(use24HourTime: v)),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Account'),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: _Row(
                  icon: Icons.cloud_outlined,
                  title: 'Backup and sync',
                  value: ref.watch(signedInUserProvider).value?.email ??
                      'Not signed in — nothing is backed up',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: 'account'),
                      builder: (BuildContext context) => const AccountScreen(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Notion'),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    _Row(
                      icon: Icons.sync_alt_rounded,
                      title: 'Notion sync',
                      value: ref
                              .watch(notionConnectionProvider)
                              .value
                              ?.workspaceName ??
                          'Not connected',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          settings: const RouteSettings(name: 'notion_connect'),
                          builder: (BuildContext context) =>
                              const NotionConnectScreen(),
                        ),
                      ),
                    ),
                    // A mapping the app chose itself has to be visible.
                    if (ref.watch(notionConnectionProvider).value != null)
                      _Row(
                        icon: Icons.table_chart_outlined,
                        title: 'Database',
                        value: ref.watch(notionMappingProvider).value?.title ??
                            'Not set up',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            settings: const RouteSettings(name: 'notion_mapping'),
                            builder: (BuildContext context) =>
                                const NotionMappingScreen(),
                          ),
                        ),
                      ),
                    // A new schema only arrives by taking the template again.
                    if (ref.watch(notionMappingProvider).value != null)
                      _Row(
                        icon: Icons.auto_awesome_motion_outlined,
                        title: 'Take the latest template',
                        value: 'Move to a new database and rewrite every row',
                        onTap: () =>
                            NotionTemplateMigration(ref).start(context),
                      ),
                    if (ref.watch(retiredNotionDatabaseProvider).value
                        case final RetiredNotionDatabase retired)
                      _Row(
                        icon: Icons.delete_outline_rounded,
                        title: 'Move the old database to trash',
                        value: retired.title,
                        onTap: () => NotionTemplateMigration(ref)
                            .trashRetired(context, retired),
                      ),
                    // Sync's own pull drops these rows, so this is the way in.
                    if (ref.watch(notionMappingProvider).value != null)
                      _Row(
                        icon: Icons.download_for_offline_outlined,
                        title: 'Import from your database',
                        value: 'Bring in classes already recorded in Notion',
                        onTap: () => _importFromNotion(context, ref),
                      ),
                    if (ref.watch(notionSyncTargetProvider) != null)
                      _Row(
                        icon: Icons.schedule_rounded,
                        title: 'Sync automatically',
                        value: 'About 15 seconds after you mark a class',
                        trailing: Switch(
                          value: settings.notionAutoSync,
                          onChanged: (bool on) => ref
                              .read(settingsProvider.notifier)
                              .save(settings.copyWith(notionAutoSync: on)),
                        ),
                      ),
                  ],
                ),
              ),
              // A failing sync has to be visible, or the app reads as working.
              if (ref.watch(notionSyncTargetProvider) != null) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                const _NotionSyncCard(),
              ],
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader('Your data'),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    _Row(
                      icon: Icons.ios_share_rounded,
                      title: 'Export backup',
                      value: 'Save a JSON file',
                      onTap: () => _export(context, ref),
                    ),
                    const Divider(indent: 58),
                    _Row(
                      icon: Icons.download_rounded,
                      title: 'Import backup',
                      value: 'Restore from a file',
                      onTap: () => _import(context, ref),
                    ),
                    const Divider(indent: 58),
                    _SwitchRow(
                      icon: Icons.backup_outlined,
                      title: 'Automatic backup',
                      subtitle: settings.autoBackupEnabled
                          ? 'Once a day, keeping the last '
                              '${BackupService.keepAutoBackups}'
                          : 'Off',
                      value: settings.autoBackupEnabled,
                      onChanged: (bool v) => controller
                          .save(settings.copyWith(autoBackupEnabled: v)),
                    ),
                    const Divider(indent: 58),
                    _Row(
                      icon: Icons.folder_outlined,
                      title: 'Backup folder',
                      value: _backupFolderLine(settings, folderUsable),
                      onTap: () => _pickBackupFolder(context, ref),
                      trailing: settings.hasBackupFolder
                          ? IconButton(
                              onPressed: () =>
                                  _clearBackupFolder(context, ref, settings),
                              icon: const Icon(Icons.close_rounded, size: 18),
                              color: context.palette.textTertiary,
                            )
                          : null,
                    ),
                    const Divider(indent: 58),
                    _Row(
                      icon: Icons.delete_forever_outlined,
                      title: 'Reset everything',
                      value: 'Delete all subjects and history',
                      danger: true,
                      onTap: () => _reset(context, ref),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Center(
                child: Text(
                  'Zeolite · 1.0.0\n'
                  'Your timetable and attendance stay on this device unless '
                  'you sign in or connect Notion. Zeolite counts how the app '
                  'is used either way.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: context.palette.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickSemesterDate(
    BuildContext context,
    SettingsController controller,
    AppSettings settings, {
    required bool isStart,
  }) async {
    final DateTime initial = isStart
        ? (settings.semesterStart ?? Dates.today())
        : (settings.semesterEnd ?? Dates.addDays(Dates.today(), 120));
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(DateTime.now().year - 2),
      lastDate: DateTime(DateTime.now().year + 4),
    );
    if (picked == null) return;

    final DateTime day = Dates.dayOf(picked);
    if (isStart) {
      final DateTime end = settings.semesterEnd ?? Dates.addDays(day, 120);
      await controller.setSemester(
        day,
        Dates.keyOf(end) < Dates.keyOf(day) ? Dates.addDays(day, 120) : end,
      );
    } else {
      final DateTime start = settings.semesterStart ?? Dates.today();
      await controller.setSemester(
        Dates.keyOf(start) > Dates.keyOf(day)
            ? Dates.addDays(day, -120)
            : start,
        day,
      );
    }
  }

  Future<void> _pickLeadTime(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
    WidgetRef ref,
  ) async {
    const List<int> options = <int>[5, 10, 15, 20, 30, 45, 60];
    final int? picked = await showAppSheet<int>(
      context: context,
      title: 'Remind me before class',
      child: Column(
        children: <Widget>[
          for (final int minutes in options)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('$minutes minutes before'),
              trailing: settings.notifyLeadMinutes == minutes
                  ? Icon(Icons.check_rounded, color: context.palette.accent)
                  : null,
              onTap: () => Navigator.of(context).pop(minutes),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await controller.save(settings.copyWith(notifyLeadMinutes: picked));
    await ref.read(actionsProvider).reloadAfterImport();
  }

  Future<void> _pickEveningTime(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
    WidgetRef ref,
  ) async {
    final TimeOfDay? picked = await showAppTimePicker(
      context,
      initialTime: TimeOfDay(
        hour: Clock.hourOf(settings.eveningReminderMinutes),
        minute: Clock.minuteOf(settings.eveningReminderMinutes),
      ),
      use24Hour: settings.use24HourTime,
    );
    if (picked == null) return;
    await controller.save(
      settings.copyWith(
        eveningReminderMinutes: Clock.toMinutes(picked.hour, picked.minute),
      ),
    );
    await ref.read(actionsProvider).reloadAfterImport();
  }

  Future<void> _deleteCategory(
    BuildContext context,
    WidgetRef ref,
    ClassCategory category,
  ) async {
    final int? id = category.id;
    if (id == null) return;

    final int inUse =
        await ref.read(actionsProvider).countSubjectsInCategory(id);
    if (!context.mounted) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: Text('Delete ${category.name}?'),
        content: Text(
          inUse == 0
              ? 'No subjects use this category.'
              : '$inUse ${inUse == 1 ? 'subject uses' : 'subjects use'} this '
                  'category. They keep all their classes and attendance — they '
                  'just fall back to the default class length.',
          style: const TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style:
                TextButton.styleFrom(foregroundColor: context.palette.absent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await ref.read(actionsProvider).deleteCategory(id);
  }

  /// Deliberately its own picker rather than following the accent: swapping
  /// the alias can take the app down with it, and the accent swatches are
  /// tapped through freely.
  Future<void> _pickLauncherIcon(BuildContext context, WidgetRef ref) async {
    final LauncherIcon inForce =
        ref.read(launcherIconProvider).value ?? LauncherIcon.standard;
    final LauncherIcon? chosen = await showDialog<LauncherIcon>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Launcher icon'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                for (final LauncherIcon icon in LauncherIcon.values)
                  _LauncherIconOption(
                    icon: icon,
                    selected: icon == inForce,
                    onTap: () => Navigator.of(context).pop(icon),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Zeolite may close while the icon changes, and your home screen '
              'can take a moment to catch up. A shortcut you pinned to the old '
              'icon stops working.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: context.palette.textTertiary,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    await ref.read(launcherIconProvider.notifier).select(chosen);
  }

  /// The one action that restates history, so it asks first.
  Future<void> _applyWeights(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Apply to every class?'),
        content: const Text(
          'Every class and every mark already recorded is set to what its '
          'category now says it is worth. A weight you set on one class by '
          'hand is replaced. You can undo this.',
          style: TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final TimetableActions actions = ref.read(actionsProvider);
    final int changed = await actions.applyClassWeights();
    showUndoSnack(
      messenger,
      actions,
      changed == 0
          ? 'Everything already matched'
          : 'Re-weighted ${Words.plural(changed, 'mark', 'marks')}',
    );
  }

  /// Named only where it is not the ordinary one.
  static String _categoryLine(
    ClassCategory category,
    List<Subject> subjects,
  ) {
    final int held = subjects
        .where((Subject s) => s.categoryId == category.id)
        .length;
    return <String>[
      held == 1 ? '1 subject' : '$held subjects',
      'defaults to ${category.durationLabel}',
      if (category.weight != 1)
        'counts as ${classWeightLabel(category.weight).toLowerCase()}',
    ].join(' · ');
  }

  /// The unavailable case is not silent: a backup still happens, and this row
  /// is where the user finds out where it went.
  static String _backupFolderLine(AppSettings settings, bool usable) {
    if (!settings.hasBackupFolder) {
      return "App's own folder — removed with the app";
    }
    final String name = settings.backupFolderName?.isNotEmpty ?? false
        ? settings.backupFolderName!
        : 'Chosen folder';
    if (!usable) return "$name is unavailable — using the app's own folder";
    return name == BackupFolder.folderName
        ? name
        : '$name/${BackupFolder.folderName}';
  }

  Future<void> _pickBackupFolder(BuildContext context, WidgetRef ref) async {
    try {
      final BackupFolder folder = BackupFolder();
      final BackupFile? picked = await folder.choose(
        initialUri: ref.read(settingsProvider).value?.backupFolderUri,
      );
      if (picked == null) return;
      // Created now, not at the first backup, so a grant that cannot write
      // fails in front of the user rather than days later.
      await folder.resolveFolder(picked.uri);
      await ref
          .read(settingsProvider.notifier)
          .setBackupFolder(picked.uri, picked.name);
      ref.invalidate(backupFolderUsableProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Automatic backups go to ${picked.name} from now on.'),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not use that folder.')),
      );
    }
  }

  Future<void> _clearBackupFolder(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final String? uri = settings.backupFolderUri;
    if (uri != null) {
      try {
        await BackupFolder().release(uri);
      } catch (_) {
      }
    }
    await ref.read(settingsProvider.notifier).clearBackupFolder();
    ref.invalidate(backupFolderUsableProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Automatic backups go to the app's own folder again."),
      ),
    );
  }

  /// Android owns the decision, so the app opens the screen and re-reads the
  /// answer once it closes.
  Future<void> _requestExactAlarms(BuildContext context, WidgetRef ref) async {
    await NotificationService.instance.requestExactAlarms();
    ref.invalidate(exactAlarmsProvider);
    await ref.read(actionsProvider).refreshNotifications();
  }

  Future<void> _addHoliday(BuildContext context, WidgetRef ref) async {
    final DateTime today = Dates.today();
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(DateTime.now().year - 1),
      lastDate: DateTime(DateTime.now().year + 3),
      currentDate: today,
      helpText: 'Pick the holiday dates',
      saveText: 'Next',
    );
    if (range == null || !context.mounted) return;

    final int days = Dates.daysBetween(range.start, range.end) + 1;
    final String? label = await showAppSheet<String>(
      context: context,
      title: days == 1 ? 'Name this holiday' : 'Name this break',
      child: SheetTextForm(
        submitLabel: days == 1 ? 'Add holiday' : 'Add $days days',
        hintText: 'e.g. Diwali, Founder\'s Day',
        textCapitalization: TextCapitalization.words,
        emptyFallback: 'Holiday',
        header: Text(
          days == 1
              ? Dates.formatFull(range.start)
              : '${Dates.formatFull(range.start)} – '
                  '${Dates.formatFull(range.end)} · $days days',
          style: TextStyle(
            fontSize: 13,
            color: context.palette.textSecondary,
          ),
        ),
      ),
    );
    if (label == null) return;

    await ref.read(actionsProvider).addHolidays(<Holiday>[
          for (int i = 0; i < days; i++)
            Holiday(date: Dates.addDays(range.start, i), name: label),
        ]);
  }

  /// A whole break going in one tap is worth naming the count for.
  Future<void> _deleteHolidayRun(
    BuildContext context,
    WidgetRef ref,
    HolidayRun run,
  ) async {
    if (run.ids.isEmpty) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    if (!run.isSingleDay) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          backgroundColor: context.palette.surfaceHigh,
          title: Text('Remove ${run.name}?'),
          content: Text(
            'All ${run.lengthLabel} go, and classes run on them again.',
            style: const TextStyle(height: 1.4),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style:
                  TextButton.styleFrom(foregroundColor: context.palette.absent),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final TimetableActions actions = ref.read(actionsProvider);
    await actions.deleteHolidays(run.ids);
    showUndoSnack(messenger, actions, '${run.name} removed');
  }

  /// Where both dialogs start. Null leaves the picker wherever it was.
  static Future<String?> _backupFolderUri(WidgetRef ref) async {
    final String? tree = ref.read(settingsProvider).value?.backupFolderUri;
    if (tree == null) return null;
    try {
      return await BackupFolder().resolveFolder(tree);
    } catch (_) {
      return null;
    }
  }

  /// Saves through the system dialog so the file lands outside the app's own
  /// folder, which is deleted with the app. Falls back to the clipboard if the
  /// dialog fails — an awkward paste beats losing the export.
  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final BackupService backup = ref.read(backupServiceProvider);
    try {
      final String json = await backup.exportToJsonString();
      final Uri? saved = await FilePicker.saveFile(
        dialogTitle: 'Save Zeolite backup',
        fileName: BackupService.fileNameFor(DateTime.now()),
        bytes: utf8.encode(json),
        mimeType: 'application/json',
        initialDirectory: await _backupFolderUri(ref),
      );
      if (!context.mounted) return;

      if (saved == null) {
        // Cancelled. Saying nothing would look like a failure.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export cancelled.')),
        );
        return;
      }
      unawaited(ref.read(analyticsProvider).backupExported());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup saved.')),
      );
    } catch (error) {
      final String json = await backup.exportToJsonString();
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open the save dialog ($error). '
              'The backup is on your clipboard instead.'),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  /// Reads the file and hands it to the preview, which owns the writing — the
  /// same split the portal page's import uses.
  Future<void> _importNotionLog(BuildContext context, WidgetRef ref) async {
    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a Notion export',
    );
    if (picked == null || !context.mounted) return;

    final NotionExport export = NotionExport.read(await picked.readAsBytes());
    if (!context.mounted) return;

    if (export.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(export.problems.isEmpty
              ? 'No classes could be read out of that file.'
              : export.problems.first),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'notion_import'),
        builder: (BuildContext context) => NotionImportScreen(export: export),
      ),
    );
  }

  /// Reads the mapped database into the same preview the CSV goes through.
  Future<void> _importFromNotion(BuildContext context, WidgetRef ref) async {
    final NotionMapping? mapping = ref.read(notionMappingProvider).value;
    if (mapping == null) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => const AlertDialog(
        content: SizedBox(
          height: 64,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    ));

    final NotionReadResult result = await NotionDatabaseReader(
      client: ref.read(notionClientProvider),
      mapping: mapping,
    ).read();
    navigator.pop();

    final NotionSource? source = result.source;
    if (source == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(_notionReadFailure(result.failure)),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    // Only worth asking where there is something of ours to leave out.
    bool skipKeyed = false;
    if (source.hasKeyedRows) {
      if (!context.mounted) return;
      final bool? answer = await _askWhichRows(context);
      if (answer == null) return;
      skipKeyed = answer;
    }

    final NotionExport export = source.read(skipKeyed: skipKeyed);
    if (export.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(export.problems.isEmpty
              ? 'Nothing in that database could be read as a class.'
              : export.problems.first),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    await navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'notion_import'),
        builder: (BuildContext context) => NotionImportScreen(export: export),
      ),
    );
  }

  /// True to skip the app's own rows; null is a cancel.
  static Future<bool?> _askWhichRows(BuildContext context) => showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          backgroundColor: context.palette.surfaceHigh,
          title: const Text('Which rows?'),
          content: const Text(
            'Some rows in that database were written by this app. Bring them '
            'in too if you are setting this device up again, or leave them out '
            'if you only want what you typed into Notion yourself.',
            style: TextStyle(height: 1.4),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Only mine'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Everything'),
            ),
          ],
        ),
      );

  static String _notionReadFailure(SyncFailure? failure) => switch (failure) {
        SyncFailure.auth =>
          'Zeolite is not allowed to read your workspace any more. Disconnect '
              'Notion and connect it again.',
        SyncFailure.offline =>
          'Could not reach Notion. Check your network and try again.',
        SyncFailure.rateLimited => 'Notion is busy. Wait a moment and try '
            'again.',
        _ => 'Notion refused that request. Check the database is still shared '
            'with Zeolite.',
      };

  /// Confirms before restoring, because the file dialog made this two taps from
  /// the Settings list and it replaces everything. Reads bytes rather than a
  /// path: a document-picker file is a `content://` URI with no path at all.
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final BackupFolder folder = BackupFolder();
    // Not `FilePicker`: its Android side never sets the initial-folder extra
    // on an open dialog, so the starting folder below would be ignored.
    final BackupFile? picked =
        await folder.pickFile(initialUri: await _backupFolderUri(ref));
    if (picked == null || !context.mounted) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Restore this backup?'),
        content: const Text(
          'Everything currently in the app is replaced by the contents of '
          'the file. This cannot be undone.',
          style: TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    late final ImportResult result;
    try {
      final String json = utf8.decode(await folder.readBytes(picked.uri));
      result = await ref.read(backupServiceProvider).importFromJsonString(json);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not read that file: $error')),
      );
      return;
    }

    if (result.success) {
      await ref.read(actionsProvider).reloadAfterImport();
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Delete everything?'),
        content: const Text(
          'Every subject, class and attendance mark will be removed. '
          'Undo puts it straight back, but only until you change something '
          'else — export a backup first if you want a copy that keeps.',
          style: TextStyle(height: 1.4),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style:
                TextButton.styleFrom(foregroundColor: context.palette.absent),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final TimetableActions actions = ref.read(actionsProvider);
    await actions.resetEverything();
    showUndoSnack(messenger, actions, 'All data deleted');
  }
}

/// The target lives in the header because everything below is computed
/// against it.
class _TargetHeader extends StatelessWidget {
  const _TargetHeader({required this.target, required this.onChanged});

  final double target;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              HeaderEyebrow('Settings'),
              SizedBox(height: 7),
              HeaderTitle('Minimum required'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              HeaderNumber('${target.round()}', size: 46),
              const SizedBox(width: 12),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: HeaderCaption(
                    'Any subject can override this from its own page.',
                    emphasis: 0.78,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.24),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withValues(alpha: 0.16),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: target.clamp(40, 100),
              min: 40,
              max: 100,
              divisions: 60,
              label: '${target.round()}%',
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.value,
    this.onTap,
    this.trailing,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return AppRow(
      icon: icon,
      title: title,
      value: value,
      tint: danger ? p.absent : p.accent,
      onTap: onTap,
      trailing: trailing,
    );
  }
}

/// One of the three theme choices, shown as a tappable tile.
class _LauncherIconOption extends StatelessWidget {
  const _LauncherIconOption({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final LauncherIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Semantics(
      label: icon.label,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(
                    color: selected ? p.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  child: Image.asset(
                    icon.preview,
                    width: 52,
                    height: 52,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                icon.label,
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? p.accent : p.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slow enough to read as the fill rising, and the curve the tab bar uses.
const Duration _toggleDuration = Duration(milliseconds: 220);
const Curve _toggleCurve = Curves.easeOutCubic;

/// A row of equal cells, the same size on a phone and on a tablet — left to
/// stretch, three across a tablet's content column stop reading as buttons.
class _SegmentedRow extends StatelessWidget {
  const _SegmentedRow({
    required this.count,
    required this.itemBuilder,
    this.phoneColumns,
  });

  static const double _maxWidth = 400;

  static const double _maxWrappedCell = 56;

  final int count;
  final Widget Function(BuildContext, int) itemBuilder;

  /// Wraps into this many columns under [AppScale.phoneWidth].
  final int? phoneColumns;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final TextScaler scaler = mq.textScaler;
    final bool wrapped =
        phoneColumns != null && mq.size.shortestSide <= AppScale.phoneWidth;
    final int columns = wrapped ? phoneColumns! : count;
    final double maxWidth = wrapped
        ? columns * _maxWrappedCell + (columns - 1) * AppSpacing.sm
        : _maxWidth;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: MediaQuery(
          // The viewer's own scaling still applies; only our ramp comes off.
          data: mq.copyWith(
            textScaler: scaler is ScaledText ? scaler.inner : scaler,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int first = 0; first < count; first += columns) ...<Widget>[
                if (first > 0) const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    for (int c = 0; c < columns; c++) ...<Widget>[
                      if (c > 0) const SizedBox(width: AppSpacing.sm),
                      // Empty columns keep the short last row lined up.
                      Expanded(
                        child: first + c < count
                            ? itemBuilder(context, first + c)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One cell: the tint sits below it when off and rises to fill it when picked.
class _SegmentedCell extends StatelessWidget {
  const _SegmentedCell({
    required this.selected,
    required this.onTap,
    required this.child,
    this.semanticsLabel,
    this.square = false,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final String? semanticsLabel;

  /// Squared off, so a round swatch is inset the same on all four sides.
  final bool square;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    Widget cell = ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: ColoredBox(color: p.surfaceHigh)),
          Positioned.fill(
            child: AnimatedFractionallySizedBox(
              duration: _toggleDuration,
              curve: _toggleCurve,
              alignment: Alignment.bottomCenter,
              heightFactor: selected ? 1 : 0,
              child: ColoredBox(color: p.accentSoft),
            ),
          ),
          // An unpositioned stack child is laid out loose, so without this
          // the cell is only tappable at its left edge.
          SizedBox(
            width: double.infinity,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: square
                    ? child
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.lg,
                        ),
                        child: child,
                      ),
              ),
            ),
          ),
        ],
      ),
    );

    if (square) cell = AspectRatio(aspectRatio: 1, child: cell);

    if (semanticsLabel == null) return cell;
    return Semantics(
      label: semanticsLabel,
      selected: selected,
      button: true,
      child: cell,
    );
  }
}

/// Below this the tick stops reading; above it the swatch reads as a button.
const double _minSwatch = 22;
const double _maxSwatch = 36;

class _AccentOption extends StatelessWidget {
  const _AccentOption({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final AccentColour accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // The swatch has to show the accent being offered, not the one in force,
    // so it is drawn from that accent's own palette at the current brightness.
    final AppPalette sample = (p.brightness == Brightness.dark
            ? AppPalette.dark
            : AppPalette.light)
        .withAccent(accent);

    return _SegmentedCell(
      selected: selected,
      onTap: onTap,
      semanticsLabel: accent.label,
      square: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double swatch =
              (c.maxWidth - AppSpacing.sm * 2).clamp(_minSwatch, _maxSwatch);
          return Center(
            child: AnimatedContainer(
              duration: _toggleDuration,
              curve: _toggleCurve,
              width: swatch,
              height: swatch,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: sample.accentGradient,
                // Slate on a dark card is barely a shape without the ring.
                border: Border.all(
                  color: selected ? sample.accent : p.outline,
                  width: 2,
                ),
              ),
              child: AnimatedScale(
                duration: _toggleDuration,
                curve: Curves.easeOutBack,
                scale: selected ? 1 : 0.4,
                child: AnimatedOpacity(
                  duration: _toggleDuration,
                  opacity: selected ? 1 : 0,
                  child: Icon(Icons.check_rounded,
                      size: swatch * 0.55, color: Colors.white),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LaunchOption extends StatelessWidget {
  const _LaunchOption({
    required this.animation,
    required this.selected,
    required this.onTap,
  });

  final LaunchAnimation animation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return _SegmentedCell(
      selected: selected,
      onTap: onTap,
      child: Column(
        children: <Widget>[
          TweenAnimationBuilder<Color?>(
            duration: _toggleDuration,
            curve: _toggleCurve,
            tween: ColorTween(end: selected ? p.accent : p.textSecondary),
            builder: (BuildContext context, Color? tone, Widget? _) => Icon(
              animation == LaunchAnimation.full
                  ? Icons.auto_awesome_rounded
                  : Icons.bolt_rounded,
              size: 22,
              color: tone,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AnimatedDefaultTextStyle(
            duration: _toggleDuration,
            curve: _toggleCurve,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? p.accent : p.textTertiary,
            ),
            child: Text(animation.label),
          ),
        ],
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final AppThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (mode) {
        AppThemeMode.system => Icons.brightness_auto_rounded,
        AppThemeMode.light => Icons.light_mode_rounded,
        AppThemeMode.dark => Icons.dark_mode_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return _SegmentedCell(
      selected: selected,
      onTap: onTap,
      child: Column(
        children: <Widget>[
          TweenAnimationBuilder<Color?>(
            duration: _toggleDuration,
            curve: _toggleCurve,
            tween: ColorTween(end: selected ? p.accent : p.textSecondary),
            builder: (BuildContext context, Color? tone, Widget? _) =>
                Icon(_icon, size: 22, color: tone),
          ),
          const SizedBox(height: AppSpacing.sm),
          AnimatedDefaultTextStyle(
            duration: _toggleDuration,
            curve: _toggleCurve,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? p.accent : p.textTertiary,
            ),
            child: Text(
              // "Match system" is too wide for a third of the row.
              mode == AppThemeMode.system ? 'System' : mode.label,
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.onTapSubtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onTapSubtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: context.palette.accent.withValues(
                alpha: context.palette.isDark ? 0.18 : 0.12,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 16,
              color: AppColors.inkOn(context.palette.accent, context.palette),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onTapSubtitle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            subtitle,
                            maxLines: 2,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: onTapSubtitle != null
                                  ? context.palette.accent
                                  : context.palette.textTertiary,
                            ),
                          ),
                        ),
                        if (onTapSubtitle != null)
                          Icon(
                            Icons.edit_rounded,
                            size: 12,
                            color: context.palette.accent,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        height: 1.4,
        color: context.palette.textTertiary,
      ),
    );
  }
}

/// A card rather than a row: a failure needs a sentence and a button.
class _NotionSyncCard extends ConsumerWidget {
  const _NotionSyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SyncStatus status = ref.watch(notionSyncStatusProvider);
    final SyncRunResult? last =
        ref.read(notionSyncStatusProvider.notifier).lastResult;
    final bool running = status.state == SyncState.running;
    final List<SyncPull> review =
        ref.read(notionSyncStatusProvider.notifier).review;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            syncStatusLine(
              status,
              last,
              storedLastSyncAt:
                  ref.watch(settingsProvider).value?.lastNotionSyncAt,
              authAdvice: 'Disconnect Notion and connect it again.',
            ),
            style: TextStyle(color: context.palette.textSecondary),
          ),
          // Saying only "synced" would let the two sides drift unremarked.
          if (review.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              onPressed: running
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          settings: const RouteSettings(name: 'notion_review'),
                          builder: (BuildContext context) =>
                              const NotionReviewScreen(),
                        ),
                      ),
              child: Text(
                'Review ${review.length} changed in Notion',
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            onPressed: running
                ? null
                : () => ref
                    .read(notionSyncStatusProvider.notifier)
                    .run(force: true),
            child: Text(status.failures > 0 ? 'Try again' : 'Sync now'),
          ),
          const SizedBox(height: AppSpacing.sm),
          // For when what the app writes has changed rather than what the
          // marks say — see `resyncEverything`.
          TextButton(
            onPressed: running
                ? null
                : () => ref
                    .read(notionSyncStatusProvider.notifier)
                    .resyncEverything(),
            child: const Text('Rewrite every row'),
          ),
        ],
      ),
    );
  }
}
