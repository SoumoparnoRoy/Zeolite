import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/models/holiday.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/holiday_runs.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/undo_snack.dart';

import 'settings_rows.dart';

class TermSection extends ConsumerWidget {
  const TermSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Term'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              SettingsRow(
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
              SettingsRow(
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
        const SettingsHint(
          'Recurring classes only appear between these dates, and the '
          '"classes left" figures are counted up to the end date.',
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
}

class CountingSection extends ConsumerWidget {
  const CountingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Counting'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: SettingsRow(
            icon: Icons.event_busy_outlined,
            title: 'Cancelled classes count as attended',
            value: 'Some institutions count them, most do not',
            trailing: Switch(
              value: settings.cancelledCountsAsAttended,
              onChanged: (bool on) => controller.save(
                settings.copyWith(cancelledCountsAsAttended: on),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        const SettingsHint(
          'Off, a cancelled class leaves your percentage alone. On, it '
          'counts as one held and one attended, which pulls the '
          'percentage up. Your figures change straight away; rows '
          'already in Notion keep their old numbers until you rewrite '
          'them.',
        ),
      ],
    );
  }
}

class HolidaysSection extends ConsumerWidget {
  const HolidaysSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TimetableData? timetable = ref.watch(timetableProvider).value;
    final List<Holiday> holidays = timetable?.holidays ?? <Holiday>[];
    final List<HolidayRun> runs = buildHolidayRuns(holidays);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
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
            child: SettingsHint(
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
                  SettingsRow(
                    icon: Icons.celebration_outlined,
                    title: runs[i].name,
                    value: runs[i].isSingleDay
                        ? runs[i].dateLabel
                        : '${runs[i].dateLabel} · ${runs[i].lengthLabel}',
                    trailing: IconButton(
                      onPressed: () => _deleteHolidayRun(context, ref, runs[i]),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: context.palette.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
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
}
