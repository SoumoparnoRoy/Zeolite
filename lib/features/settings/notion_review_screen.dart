import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../domain/sync/sync_merge.dart';
import '../../domain/sync/sync_plan.dart';
import '../../state/notion_sync_providers.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// Rows somebody edited in Notion since the app last wrote them.
///
/// Never applied on their own: a person types into that table by hand, so a
/// difference is a claim to look at rather than a newer truth. The app's own
/// marks are only overwritten by an answer given here.
class NotionReviewScreen extends ConsumerStatefulWidget {
  const NotionReviewScreen({super.key});

  @override
  ConsumerState<NotionReviewScreen> createState() => _NotionReviewScreenState();
}

class _NotionReviewScreenState extends ConsumerState<NotionReviewScreen> {
  late final List<SyncPull> _pulls =
      ref.read(notionSyncStatusProvider.notifier).review;

  /// Defaults to keeping what is here. Taking a hand edit over a tap in the
  /// app is the bigger claim, so it is the one that has to be chosen.
  late final Map<String, SyncSide> _choices = <String, SyncSide>{
    for (final SyncPull pull in _pulls) pull.remote.localKey: SyncSide.here,
  };

  bool _applying = false;

  Future<void> _apply() async {
    setState(() => _applying = true);
    final NavigatorState navigator = Navigator.of(context);
    await ref
        .read(notionSyncStatusProvider.notifier)
        .applyReview(Map<String, SyncSide>.from(_choices));
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final TimetableData? data = ref.watch(timetableProvider).value;
    final List<Subject> subjects = data?.subjects ?? const <Subject>[];
    final List<AttendanceRecord> records =
        data?.records ?? const <AttendanceRecord>[];
    final int taking = _choices.values
        .where((SyncSide side) => side == SyncSide.there)
        .length;

    return PushScaffold(
      title: 'Changed in Notion',
      subtitle: '${_pulls.length} row${_pulls.length == 1 ? '' : 's'}',
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_pulls.isEmpty)
                  const EmptyState(
                    icon: Icons.done_all_rounded,
                    title: 'Nothing to review',
                    message: 'Notion agrees with this device.',
                  )
                else ...<Widget>[
                  Text(
                    'These were edited in Notion. Nothing here has changed '
                    'yet.',
                    style: TextStyle(color: context.palette.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  for (final SyncPull pull in _pulls) ...<Widget>[
                    _Row(
                      pull: pull,
                      subjects: subjects,
                      records: records,
                      side: _choices[pull.remote.localKey] ?? SyncSide.here,
                      onChanged: (SyncSide side) => setState(
                        () => _choices[pull.remote.localKey] = side,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton(
                    onPressed: _applying ? null : _apply,
                    child: Text(
                      taking == 0
                          ? 'Keep all of mine'
                          : 'Apply — take $taking from Notion',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Anything you keep is written back over the Notion row on '
                    'the next sync.',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.textTertiary,
                    ),
                  ),
                ],
                if (_applying) ...<Widget>[
                  const SizedBox(height: AppSpacing.lg),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One disagreement, and the two ways to settle it.
class _Row extends StatelessWidget {
  const _Row({
    required this.pull,
    required this.subjects,
    required this.records,
    required this.side,
    required this.onChanged,
  });

  final SyncPull pull;
  final List<Subject> subjects;
  final List<AttendanceRecord> records;
  final SyncSide side;
  final ValueChanged<SyncSide> onChanged;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _title(),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Notion says ${_describe(pull.remote.fields)}',
            style: TextStyle(color: context.palette.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _here(),
            style: TextStyle(
              color: _mark() == null
                  ? context.palette.warning
                  : context.palette.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: _Choice(
                  label: 'Keep mine',
                  selected: side == SyncSide.here,
                  onTap: () => onChanged(SyncSide.here),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _Choice(
                  label: 'Take theirs',
                  selected: side == SyncSide.there,
                  onTap: () => onChanged(SyncSide.there),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// `uuid:20260304:540` is all the key carries, so the course is looked up
  /// and the rest is read straight out of it.
  String _title() {
    final List<String> parts = pull.remote.localKey.split(':');
    final String uuid = parts.isNotEmpty ? parts.first : '';
    final String name = subjects
        .firstWhere(
          (Subject s) => s.uuid == uuid,
          orElse: () => const Subject(name: 'A class', colorValue: 0),
        )
        .name;

    final int? key = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (key == null) return name;
    final DateTime date = Dates.fromKey(key);
    return '$name · ${Dates.formatDayMonth(date)}';
  }

  /// The mark this key names, or null when there is none.
  ///
  /// A row with nothing here is the case worth seeing: it cannot be answered
  /// by keeping a local mark that does not exist, and choosing to keep this
  /// side retires the page instead.
  AttendanceRecord? _mark() {
    final List<String> parts = pull.remote.localKey.split(':');
    if (parts.length < 3) return null;
    final int? key = int.tryParse(parts[1]);
    final int? start = int.tryParse(parts[2]);
    if (key == null || start == null) return null;

    final int? subjectId = subjects
        .where((Subject s) => s.uuid == parts.first)
        .firstOrNull
        ?.id;
    if (subjectId == null) return null;

    return records
        .where((AttendanceRecord r) =>
            r.subjectId == subjectId &&
            r.startMinutes == start &&
            Dates.keyOf(r.date) == key)
        .firstOrNull;
  }

  String _here() {
    final AttendanceRecord? mark = _mark();
    if (mark == null) return 'Not marked on this device';
    return 'Here it is ${_describe(<String, Object?>{
          'status': mark.status.name,
          'weight': mark.weight,
        })}';
  }

  static String _describe(Map<String, Object?> fields) {
    final String status = (fields['status'] as String?) ?? 'present';
    final Object? weight = fields['weight'];
    final String label =
        AttendanceStatus.fromName(status)?.label ?? _capitalise(status);
    return weight is int && weight != 1 ? '$label, counts as $weight' : label;
  }

  static String _capitalise(String value) => value.isEmpty
      ? value
      : '${value[0].toUpperCase()}${value.substring(1)}';
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? p.accent : p.textSecondary,
        side: BorderSide(
          color: selected ? p.accent : p.textTertiary.withValues(alpha: 0.4),
        ),
      ),
      child: Text(label),
    );
  }
}
