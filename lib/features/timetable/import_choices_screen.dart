import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../domain/timetable_choices.dart';
import '../../domain/timetable_ocr.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// Narrows a division's timetable down to one student's.
///
/// Every question on one screen rather than a stack of prompts, because this
/// is the same pass a student makes with a pen over their own copy. Nothing is
/// discarded: the answers decide which lines the import screen comments out,
/// and any question may be left alone.
class ImportChoicesScreen extends StatefulWidget {
  const ImportChoicesScreen({
    super.key,
    required this.entries,
    required this.axes,
    required this.baskets,
    required this.use24Hour,
  });

  final List<OcrEntry> entries;

  /// Group markers by the axis they answer — `B` to `[B1, B2, B3]`.
  final Map<String, List<String>> axes;

  final List<ElectiveBasket> baskets;
  final bool use24Hour;

  @override
  State<ImportChoicesScreen> createState() => _ImportChoicesScreenState();
}

class _ImportChoicesScreenState extends State<ImportChoicesScreen> {
  final Map<String, String> _byAxis = <String, String>{};
  final Map<int, String> _byBasket = <int, String>{};

  TimetableChoices get _choices => TimetableChoices(
        baskets: widget.baskets,
        groups: _byAxis.values.toSet(),
        electives: _byBasket,
      );

  /// Tapping the given answer clears it, the only way back to keeping all.
  void _toggleAxis(String axis, String group) => setState(() {
        if (_byAxis[axis] == group) {
          _byAxis.remove(axis);
        } else {
          _byAxis[axis] = group;
        }
      });

  void _toggleBasket(int index, String subject) => setState(() {
        if (_byBasket[index] == subject) {
          _byBasket.remove(index);
        } else {
          _byBasket[index] = subject;
        }
      });

  @override
  Widget build(BuildContext context) {
    final TimetableChoices choices = _choices;
    final int kept = widget.entries.where(choices.keeps).length;

    return PushScaffold(
      title: 'Which of these are yours?',
      subtitle: '${Words.plural(kept, 'class', 'classes')} of '
          '${widget.entries.length}',
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          sliver: SliverList.list(children: <Widget>[
            const GroupNote(
              'This sheet is printed for the whole division. Pick yours and '
              'the rest stay in the box, commented out.',
            ),
            for (final MapEntry<String, List<String>> axis
                in widget.axes.entries) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              SectionHeader(_axisTitle(axis.key)),
              _Choices(
                options: axis.value,
                chosen: _byAxis[axis.key],
                onTap: (String group) => _toggleAxis(axis.key, group),
              ),
            ],
            for (int i = 0; i < widget.baskets.length; i++) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              SectionHeader(widget.baskets.length == 1
                  ? 'ELECTIVE'
                  : 'ELECTIVE ${i + 1}'),
              GroupNote(_whenItRuns(widget.baskets[i])),
              _Choices(
                options: widget.baskets[i].subjects,
                chosen: _byBasket[i],
                onTap: (String subject) => _toggleBasket(i, subject),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(choices),
              child: Text('Read ${Words.plural(kept, 'line')}'),
            ),
          ]),
        ),
      ],
    );
  }

  /// `B` and `G` are the only markers the parser recognises.
  static String _axisTitle(String axis) => switch (axis) {
        'B' => 'BATCH',
        'G' => 'GROUP',
        _ => 'GROUP $axis',
      };

  String _whenItRuns(ElectiveBasket basket) {
    final List<String> days = <String>[];
    for (final (int, int, int) slot in basket.slots) {
      final String day = kWeekdayNamesLong[slot.$1 - 1];
      if (!days.contains(day)) days.add(day);
    }
    final String at = Clock.format(
      basket.slots.first.$2,
      use24Hour: widget.use24Hour,
    );
    return '${_listed(days)} at $at.';
  }

  /// `Tuesday, Wednesday and Thursday`.
  static String _listed(List<String> items) {
    if (items.length < 2) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} '
        'and ${items.last}';
  }
}

class _Choices extends StatelessWidget {
  const _Choices({
    required this.options,
    required this.chosen,
    required this.onTap,
  });

  final List<String> options;
  final String? chosen;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Column(
        children: <Widget>[
          for (final String option in options)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(option),
              trailing: chosen == option
                  ? Icon(Icons.check_rounded, color: context.palette.accent)
                  : null,
              onTap: () => onTap(option),
            ),
        ],
      ),
    );
  }
}
