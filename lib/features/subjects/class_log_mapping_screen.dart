import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../domain/class_log.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../domain/notion_export.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';
import 'class_editor/editor_fields.dart';

/// Matches a class log's columns to fields, and its status and type words to
/// meanings. Every status word found gets a row, because a word left
/// unanswered is a class the import would drop.
class ClassLogMappingScreen extends StatefulWidget {
  const ClassLogMappingScreen({
    super.key,
    required this.table,
    required this.initial,
  });

  final ClassLogTable table;
  final ClassLogMapping initial;

  @override
  State<ClassLogMappingScreen> createState() => _ClassLogMappingScreenState();
}

class _ClassLogMappingScreenState extends State<ClassLogMappingScreen> {
  late ClassLogMapping _mapping = widget.initial;

  ClassLogTable get _table => widget.table;

  static const Map<NotionField, String> _descriptions = <NotionField, String>{
    NotionField.course: 'Which subject each class belongs to.',
    NotionField.date: 'The day each class was held.',
    NotionField.status: 'Whether you were there, or the class was cancelled.',
    NotionField.component: 'A code or title per row, used for the course code.',
    NotionField.time: 'Start time as 09:00, where the file has one.',
    NotionField.kind: 'Lecture, lab or tutorial, in the file\'s own words.',
    NotionField.held: 'How many classes a row counts as.',
    NotionField.credit: 'How many of those you were credited with.',
  };

  void _setColumn(NotionField field, int? column) => setState(() {
        final Map<NotionField, int> columns =
            Map<NotionField, int>.of(_mapping.columns);
        if (column == null) {
          columns.remove(field);
        } else {
          columns.removeWhere((NotionField f, int c) => c == column);
          columns[field] = column;
        }
        // A new status or type column brings words the old one did not have.
        _mapping = ClassLogMapping(
          columns: columns,
          statuses: field == NotionField.status
              ? const <String, LogVerdict>{}
              : _mapping.statuses,
          types: field == NotionField.kind
              ? const <String, NotionKind>{}
              : _mapping.types,
          dayFirst: field == NotionField.date ? null : _mapping.dayFirst,
        ).withGuessedWords(_table);
      });

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final int? statusColumn = _mapping.columns[NotionField.status];
    final int? kindColumn = _mapping.columns[NotionField.kind];
    final int? dateColumn = _mapping.columns[NotionField.date];
    final bool ready = _mapping.readyFor(_table);

    return PushScaffold(
      title: 'Read the file',
      subtitle: '${_table.rows.length} rows · ${_table.header.length} columns',
      // Hidden until every row can be read, rather than offered and refused.
      floatingActionButton: ready
          ? GradientFab(
              label: 'Continue to preview',
              onPressed: () => Navigator.of(context).pop(_mapping),
            )
          : null,
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
          sliver: SliverList.list(
            children: <Widget>[
              Text(
                'Zeolite filled in what it recognised. Match the rest and it '
                'will remember this layout for next time.',
                style: TextStyle(fontSize: 12.5, color: p.textTertiary),
              ),
              const SizedBox(height: AppSpacing.lg),
              const SectionHeader('Columns'),
              for (final NotionField field in ClassLogMapping.fields) ...<Widget>[
                _Choice<int>(
                  title: field.isRequired ? '${field.label} *' : field.label,
                  subtitle: _descriptions[field],
                  value: _mapping.columns[field],
                  emptyLabel: field.isRequired ? 'Choose' : 'Not in file',
                  allowEmpty: !field.isRequired,
                  options: <int, String>{
                    for (int i = 0; i < _table.header.length; i++)
                      i: _table.header[i].isEmpty
                          ? 'Column ${i + 1}'
                          : _table.header[i],
                  },
                  onChanged: (int? column) => _setColumn(field, column),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (ClassLogMapping.datesAreAmbiguous(_table, dateColumn))
                _DateOrder(
                  sample: _table.valuesOf(dateColumn).firstWhere(
                        (String v) => ClassLogMapping.numericDate(v) != null,
                      ),
                  dayFirst: _mapping.dayFirst,
                  onChanged: (bool dayFirst) => setState(
                    () => _mapping = _mapping.copyWith(dayFirst: dayFirst),
                  ),
                ),
              if (statusColumn != null) ...<Widget>[
                const SizedBox(height: AppSpacing.lg),
                const SectionHeader('What each status means'),
                Text(
                  'Present, absent and cancelled are the marks. Any other word '
                  'can ride on one of them as a tag, in the file\'s spelling.',
                  style: TextStyle(fontSize: 12, color: p.textTertiary),
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final String word in _table.valuesOf(statusColumn)) ...<Widget>[
                  _Choice<LogVerdict>(
                    title: word,
                    value: _mapping.statuses[word.toLowerCase()],
                    emptyLabel: 'Choose',
                    options: <LogVerdict, String>{
                      LogVerdict.present: 'Present',
                      LogVerdict.absent: 'Absent',
                      LogVerdict.cancelled: 'Cancelled',
                      LogVerdict.presentTagged: 'Present, tagged "$word"',
                      LogVerdict.absentTagged: 'Absent, tagged "$word"',
                      LogVerdict.leftOut: 'Leave these rows out',
                    },
                    onChanged: (LogVerdict? verdict) => setState(() {
                      _mapping = _mapping.copyWith(
                        statuses: <String, LogVerdict>{
                          ..._mapping.statuses,
                          if (verdict != null) word.toLowerCase(): verdict,
                        },
                      );
                    }),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
              if (kindColumn != null) ...<Widget>[
                const SizedBox(height: AppSpacing.lg),
                const SectionHeader('What each type is'),
                Text(
                  'Only decides which rows are labs. Each type keeps the '
                  'file\'s own name in the app.',
                  style: TextStyle(fontSize: 12, color: p.textTertiary),
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final String word in _table.valuesOf(kindColumn)) ...<Widget>[
                  _Choice<NotionKind>(
                    title: word,
                    value: _mapping.types[word.toLowerCase()],
                    emptyLabel: 'Lecture',
                    options: const <NotionKind, String>{
                      NotionKind.lecture: 'Lecture',
                      NotionKind.tutorial: 'Tutorial',
                      NotionKind.practical: 'Practical (lab)',
                    },
                    onChanged: (NotionKind? kind) => setState(() {
                      _mapping = _mapping.copyWith(
                        types: <String, NotionKind>{
                          ..._mapping.types,
                          if (kind != null) word.toLowerCase(): kind,
                        },
                      );
                    }),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A label and a dropdown, the shape every row of this screen takes.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.title,
    required this.value,
    required this.options,
    required this.emptyLabel,
    required this.onChanged,
    this.subtitle,
    this.allowEmpty = false,
  });

  final String title;
  final String? subtitle;
  final T? value;
  final Map<T, String> options;
  final String emptyLabel;
  final bool allowEmpty;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: context.palette.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: DropdownButton<T>(
              isExpanded: true,
              value: options.containsKey(value) ? value : null,
              hint: Text(
                emptyLabel,
                style: TextStyle(color: context.palette.textTertiary),
              ),
              items: <DropdownMenuItem<T>>[
                if (allowEmpty)
                  DropdownMenuItem<T>(child: Text(emptyLabel)),
                for (final MapEntry<T, String> option in options.entries)
                  DropdownMenuItem<T>(
                    value: option.key,
                    child: Text(option.value, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// For dates like 05/08/2026, which read as a real day either way round.
class _DateOrder extends StatelessWidget {
  const _DateOrder({
    required this.sample,
    required this.dayFirst,
    required this.onChanged,
  });

  final String sample;
  final bool? dayFirst;
  final ValueChanged<bool> onChanged;

  String _readAs(bool first) {
    final DateTime? date =
        NotionExport.dateOf(sample, Dates.today(), dayFirst: first);
    return date == null ? 'not a date' : Dates.formatFull(date);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Which comes first in the dates?',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              '"$sample" could be either.',
              style: TextStyle(fontSize: 12, color: context.palette.textTertiary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                OptionChip(
                  label: 'Day · ${_readAs(true)}',
                  selected: dayFirst == true,
                  onTap: () => onChanged(true),
                ),
                OptionChip(
                  label: 'Month · ${_readAs(false)}',
                  selected: dayFirst == false,
                  onTap: () => onChanged(false),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
