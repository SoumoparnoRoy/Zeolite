import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/words.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/subject.dart';
import '../../domain/untimed_match.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/untimed_match_dialog.dart';

/// The same matching the class editors offer after a save, for whoever said
/// "Not now" there or added their classes some other way.
class UntimedMatchScreen extends ConsumerStatefulWidget {
  const UntimedMatchScreen({super.key});

  @override
  ConsumerState<UntimedMatchScreen> createState() => _UntimedMatchScreenState();
}

class _UntimedMatchScreenState extends ConsumerState<UntimedMatchScreen> {
  /// Unticked rather than ticked subjects, so every subject starts ticked.
  final Set<int> _skipped = <int>{};
  bool _saving = false;

  Future<void> _apply(List<UntimedMatch> matches) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ActionCore core = ref.read(actionCoreProvider);
    final int count =
        await ref.read(attendanceActionsProvider).matchUntimed(matches);
    if (!mounted) return;
    navigator.pop();
    showUndoSnack(messenger, core, matchedMessage(count));
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final TimetableData? data = ref.watch(timetableProvider).value;
    final List<UntimedMatch> all = ref.watch(untimedMatchesProvider);

    final Map<int, int> untimed = <int, int>{};
    for (final AttendanceRecord record
        in data?.records ?? const <AttendanceRecord>[]) {
      if (AttendanceRecord.isTimed(record.startMinutes)) continue;
      untimed[record.subjectId] = (untimed[record.subjectId] ?? 0) + 1;
    }
    final Map<int, int> matchable = <int, int>{};
    for (final UntimedMatch match in all) {
      final int id = match.record.subjectId;
      matchable[id] = (matchable[id] ?? 0) + 1;
    }

    final List<Subject> subjects = <Subject>[
      for (final Subject subject in data?.subjects ?? const <Subject>[])
        if (matchable.containsKey(subject.id)) subject,
    ];
    final String other = subjects.isEmpty ? '' : 'other ';
    final List<UntimedMatch> chosen = <UntimedMatch>[
      for (final UntimedMatch match in all)
        if (!_skipped.contains(match.record.subjectId)) match,
    ];
    // Subjects with some matches say what is left on their own row.
    int stranded = 0;
    untimed.forEach((int id, int n) {
      if (!matchable.containsKey(id)) stranded += n;
    });

    return PushScaffold(
      title: 'Match classes with no time',
      subtitle: all.isEmpty
          ? 'Nothing to match yet'
          : '${Words.plural(all.length, 'class', 'classes')} can be matched',
      floatingActionButton: all.isEmpty
          ? null
          : GradientFab(
              label: chosen.isEmpty
                  ? 'Match'
                  : 'Match ${Words.plural(chosen.length, 'class', 'classes')}',
              onPressed:
                  chosen.isEmpty || _saving ? null : () => _apply(chosen),
            ),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          sliver: SliverList.list(
            children: <Widget>[
              Text(
                'Classes imported without a time show only in the log. Where '
                'the timetable now has a class of that subject on the same '
                'day, matching files the mark under it, so it shows as marked. '
                'Status, weight and tags stay as they are.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (subjects.isNotEmpty) const SectionHeader('Subjects'),
              for (final Subject subject in subjects) ...<Widget>[
                _SubjectRow(
                  subject: subject,
                  matchable: matchable[subject.id]!,
                  left: (untimed[subject.id] ?? 0) - matchable[subject.id]!,
                  ticked: !_skipped.contains(subject.id),
                  onToggle: () => setState(() {
                    if (!_skipped.remove(subject.id!)) {
                      _skipped.add(subject.id!);
                    }
                  }),
                ),
                const SizedBox(height: 10),
              ],
              if (stranded > 0)
                Text(
                  stranded == 1
                      ? 'One ${other}class has no class of its subject on the '
                          'timetable that day, so it keeps no time.'
                      : '$stranded ${other}classes have no class of their '
                          'subject on the timetable that day, so they keep no '
                          'time.',
                  style:
                      TextStyle(fontSize: 12, height: 1.45, color: p.textFaint),
                ),
              if (untimed.isEmpty)
                Text(
                  'Every class has a time.',
                  style:
                      TextStyle(fontSize: 12, height: 1.45, color: p.textFaint),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SubjectRow extends StatelessWidget {
  const _SubjectRow({
    required this.subject,
    required this.matchable,
    required this.left,
    required this.ticked,
    required this.onToggle,
  });

  final Subject subject;
  final int matchable;
  final int left;
  final bool ticked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SurfaceCard(
      onTap: onToggle,
      child: Row(
        children: <Widget>[
          Checkbox.adaptive(
            value: ticked,
            onChanged: (_) => onToggle(),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  subject.name,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: ticked ? p.textPrimary : p.textFaint,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  left > 0
                      ? '${Words.plural(matchable, 'class', 'classes')} to '
                          'match · $left with no class to go to'
                      : '${Words.plural(matchable, 'class', 'classes')} to '
                          'match',
                  style: TextStyle(fontSize: 12, color: p.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
