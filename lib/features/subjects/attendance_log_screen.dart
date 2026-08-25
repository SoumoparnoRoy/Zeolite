import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/attendance_log.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// Every past class for one subject, with its mark, correctable in place.
///
/// Exists because the Today screen only reaches one day at a time: fixing a
/// mistake from three weeks ago meant walking back through it day by day.
class AttendanceLogScreen extends ConsumerWidget {
  const AttendanceLogScreen({super.key, required this.subject});

  final Subject subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int? subjectId = subject.id;
    if (subjectId == null) {
      // Defensive: a subject always has an id once persisted, but the model
      // allows null before insertion and a blank screen would be worse.
      return PushScaffold(
        title: subject.name,
        slivers: const <Widget>[
          SliverFillRemaining(
            hasScrollBody: false,
            child: _LogEmpty(message: 'This subject has not been saved yet.'),
          ),
        ],
      );
    }

    final List<AttendanceLogEntry> entries =
        ref.watch(attendanceLogProvider(subjectId));
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final int marked =
        entries.where((AttendanceLogEntry e) => e.isMarked).length;

    if (entries.isEmpty) {
      return PushScaffold(
        title: subject.name,
        slivers: <Widget>[
          if (subject.priorHeld > 0)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              sliver: SliverToBoxAdapter(child: _CarriedIn(subject: subject)),
            ),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _LogEmpty(
              message: 'Once this subject has had a class, every one of them '
                  'shows up here to mark or correct.',
            ),
          ),
        ],
      );
    }

    final List<_Row> rows = _flatten(entries);

    return PushScaffold(
      title: subject.name,
      subtitle: '$marked of ${entries.length} marked',
      slivers: <Widget>[
        if (subject.priorHeld > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            sliver: SliverToBoxAdapter(child: _CarriedIn(subject: subject)),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          sliver: SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (BuildContext context, int index) {
              final _Row row = rows[index];
              if (row.isHeader) {
                return Padding(
                  padding: EdgeInsets.only(top: index == 0 ? 0 : 18),
                  child: SectionHeader(row.header!),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _LogTile(
                  subjectId: subjectId,
                  entry: row.entry!,
                  use24Hour: settings.use24HourTime,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Month headings and classes flattened into one list, so a single builder
  /// can render a whole term lazily rather than building rows it never shows.
  List<_Row> _flatten(List<AttendanceLogEntry> entries) {
    final List<_Row> rows = <_Row>[];
    String? currentMonth;
    for (final AttendanceLogEntry entry in entries) {
      final String month = Dates.formatMonthYear(entry.date);
      if (month != currentMonth) {
        currentMonth = month;
        rows.add(_Row.header(month));
      }
      rows.add(_Row.entry(entry));
    }
    return rows;
  }
}

/// The classes counted before the app existed. They have no dates, so they
/// cannot be rows — without this the log looks like it has lost them.
class _CarriedIn extends StatelessWidget {
  const _CarriedIn({required this.subject});

  final Subject subject;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Carried in',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.textFaint,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${subject.priorAttended} of ${subject.priorHeld} attended before '
            'this app started counting',
            style: const TextStyle(fontSize: 13, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _LogEmpty extends StatelessWidget {
  const _LogEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 40, bottom: 60),
      child: EmptyState(
        icon: Icons.history_rounded,
        title: 'Nothing to show yet',
        message: message,
      ),
    );
  }
}

@immutable
class _Row {
  const _Row.header(this.header) : entry = null;
  const _Row.entry(this.entry) : header = null;

  final String? header;
  final AttendanceLogEntry? entry;

  bool get isHeader => header != null;
}

class _LogTile extends ConsumerWidget {
  const _LogTile({
    required this.subjectId,
    required this.entry,
    required this.use24Hour,
  });

  final int subjectId;
  final AttendanceLogEntry entry;
  final bool use24Hour;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppPalette p = context.palette;
    final String? tagName =
        ref.watch(timetableProvider).value?.tagById(entry.tagId)?.name;

    final String time = entry.endMinutes == null
        ? Clock.format(entry.startMinutes, use24Hour: use24Hour)
        : Clock.formatRange(
            entry.startMinutes,
            entry.endMinutes!,
            use24Hour: use24Hour,
          );

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      // Unmarked rows are the ones worth chasing, so they carry a hint of the
      // warning colour instead of sitting silently in the list. With outlines
      // gone the hint has to be in the fill.
      color: entry.needsMarking
          ? Color.alphaBlend(p.warning.withValues(alpha: 0.09), p.surface)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      Dates.formatFull(entry.date),
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      <String>[
                        Dates.weekdayLong(entry.date),
                        time,
                        if (entry.room != null && entry.room!.isNotEmpty)
                          entry.room!,
                        if (tagName != null) tagName,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(color: p.textTertiary, size: 10),
                    ),
                  ],
                ),
              ),
              for (final AttendanceStatus status in AttendanceStatus.values)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _StatusToggle(
                    status: status,
                    selected: entry.status == status,
                    // Same reason as the Today card: the row is replaced on
                    // write, so the tag has to be handed back or correcting
                    // Present to Absent would quietly strip it.
                    onTap: () => ref.read(actionsProvider).setStatusAt(
                          subjectId: subjectId,
                          date: entry.date,
                          startMinutes: entry.startMinutes,
                          current: entry.status,
                          status: status,
                          weight: entry.weight,
                          tagId: entry.tagId,
                        ),
                  ),
                ),
            ],
          ),
          if (entry.isOrphaned) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.link_off_rounded, size: 13, color: p.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'No class on your timetable sits here — the rule was '
                    'removed, or this mark was brought in from elsewhere. It '
                    'still counts towards your percentage.',
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.4,
                      color: p.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _confirmRemove(context, ref),
                icon: const Icon(Icons.delete_outline_rounded, size: 15),
                label: const Text('Remove this mark'),
                style: TextButton.styleFrom(
                  foregroundColor: p.absent,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  textStyle: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Confirms before discarding a stray mark.
///
/// There is no undo anywhere in the app, and this row is the only place the
/// mark is visible at all, so removing it silently would destroy the one thing
/// that explains a percentage the user cannot otherwise account for.
extension on _LogTile {
  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Remove this mark?'),
            content: Text(
              'The ${entry.status?.label.toLowerCase() ?? 'recorded'} mark for '
              '${Dates.formatFull(entry.date)} will be deleted and will stop '
              'counting towards your percentage. This cannot be undone.',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep it'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: context.palette.absent,
                ),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;
    await ref.read(actionsProvider).clearStatusAt(
          subjectId: subjectId,
          date: entry.date,
          startMinutes: entry.startMinutes,
        );
  }
}

/// Compact icon-only toggle. A term's worth of rows cannot afford the
/// full-width labelled buttons the Today screen uses, so the label moves into
/// the semantics and tooltip rather than disappearing.
class _StatusToggle extends StatelessWidget {
  const _StatusToggle({
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final AttendanceStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color color = status.colorIn(p);

    return Tooltip(
      message: selected ? 'Clear ${status.label}' : status.label,
      child: Semantics(
        button: true,
        selected: selected,
        label: status.label,
        child: Material(
          color: selected ? color.withValues(alpha: 0.14) : p.surfaceHigh,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            child: SizedBox(
              // 44px keeps the target at the accessible minimum even though
              // the icon inside is small.
              width: 44,
              height: 44,
              child: Icon(
                status.icon,
                size: 18,
                color: selected ? color : p.textFaint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
