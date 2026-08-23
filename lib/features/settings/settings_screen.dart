import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/time_picker.dart';
import '../../data/models/class_category.dart';
import '../../data/models/holiday.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/holiday_runs.dart';
import '../../services/backup_folder.dart';
import '../../services/backup_service.dart';
import '../../services/notification_service.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../subjects/class_editor_sheets.dart';
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
              const SectionHeader('Semester'),
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
                      builder: (BuildContext context) =>
                          const ImportTimetableScreen(),
                    ),
                  ),
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
                    'No categories yet. Create one — Lab, Theory, Tutorial — and '
                    'give it a default length, then put your subjects in it.',
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
                          value: 'Classes default to '
                              '${categories[i].durationLabel}',
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
                child: Row(
                  children: <Widget>[
                    for (final AppThemeMode mode in AppThemeMode.values)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right:
                                mode == AppThemeMode.dark ? 0 : AppSpacing.sm,
                          ),
                          child: _ThemeOption(
                            mode: mode,
                            selected: settings.themeMode == mode,
                            onTap: () => controller
                                .save(settings.copyWith(themeMode: mode)),
                          ),
                        ),
                      ),
                  ],
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
                  subtitle: settings.use24HourTime ? '14:30' : '2:30 pm',
                  value: settings.use24HourTime,
                  onChanged: (bool v) =>
                      controller.save(settings.copyWith(use24HourTime: v)),
                ),
              ),
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
                  'Zeolite · 1.0.0\nAll your data stays on this device.',
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

  /// The unavailable case is not silent: a backup still happens, and this row
  /// is where the user finds out where it went.
  static String _backupFolderLine(AppSettings settings, bool usable) {
    if (!settings.hasBackupFolder) {
      return "App's own folder — removed with the app";
    }
    final String name = settings.backupFolderName?.isNotEmpty ?? false
        ? settings.backupFolderName!
        : 'Chosen folder';
    return usable
        ? '$name/${BackupFolder.folderName}'
        : "$name is unavailable — using the app's own folder";
  }

  Future<void> _pickBackupFolder(BuildContext context, WidgetRef ref) async {
    try {
      final BackupFolder folder = BackupFolder();
      final BackupFile? picked = await folder.choose();
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

    await ref.read(actionsProvider).deleteHolidays(run.ids);
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
      );
      if (!context.mounted) return;

      if (saved == null) {
        // Cancelled. Saying nothing would look like a failure.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export cancelled.')),
        );
        return;
      }
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

  /// Confirms before restoring, because the file dialog made this two taps from
  /// the Settings list and it replaces everything. Reads bytes rather than a
  /// path: a document-picker file is a `content://` URI with no path at all.
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a Zeolite backup',
    );
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
      final String json = utf8.decode(await picked.readAsBytes());
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
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: context.palette.surfaceHigh,
        title: const Text('Delete everything?'),
        content: const Text(
          'Every subject, class and attendance mark will be removed. '
          'Export a backup first if you might want this data back.',
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
    await ref.read(actionsProvider).resetEverything();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('All data deleted')));
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
    return Material(
      color: selected ? p.accentSoft : p.surfaceHigh,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
          child: Column(
            children: <Widget>[
              Icon(
                _icon,
                size: 22,
                color: selected ? p.accent : p.textSecondary,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                // "Match system" is too wide for a third of the row.
                mode == AppThemeMode.system ? 'System' : mode.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
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
