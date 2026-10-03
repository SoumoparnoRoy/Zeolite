import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../data/models/class_category.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../state/notion_mapping_form.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// Choosing where attendance is filed in Notion, and which column holds what.
///
/// Three stages in one route rather than three pushes: picking a database and
/// then a column inside it is one decision the user is making, and a back
/// stack through it would let them leave half a mapping behind.
class NotionMappingScreen extends ConsumerWidget {
  const NotionMappingScreen({super.key, this.onlyUnmapped = false});

  /// Shows only what a template did not match, with a way past it. The whole
  /// form would bury two gaps among ten rows that are already right.
  final bool onlyUnmapped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NotionMappingForm form =
        ref.watch(notionMappingFormProvider(onlyUnmapped));
    final _MappingBody body = _MappingBody(
      form: form,
      controller: ref.read(notionMappingFormProvider(onlyUnmapped).notifier),
      categories: ref.watch(timetableProvider).value?.categories ??
          const <ClassCategory>[],
    );
    return PushScaffold(
      title: 'Notion table',
      subtitle: switch (form.stage) {
        NotionMappingStage.sources => 'Where should attendance go?',
        _ => form.databaseTitle.isEmpty ? null : form.databaseTitle,
      },
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
                if (form.error != null) ...<Widget>[
                  Text(form.error!,
                      style: TextStyle(color: context.palette.absent)),
                  const SizedBox(height: AppSpacing.lg),
                ],
                ...switch (form.stage) {
                  NotionMappingStage.loading => const <Widget>[],
                  NotionMappingStage.sources => body.sourceList(context),
                  NotionMappingStage.fields => body.fieldForm(context),
                },
                if (form.busy) ...<Widget>[
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

/// The two stages' contents, kept out of `build` so each reads on its own.
class _MappingBody {
  const _MappingBody({
    required this.form,
    required this.controller,
    required this.categories,
  });

  final NotionMappingForm form;
  final NotionMappingFormController controller;
  final List<ClassCategory> categories;

  bool get _busy => form.busy;

  static TextStyle _hint(BuildContext context) => TextStyle(
        fontSize: 12,
        height: 1.3,
        color: context.palette.textTertiary,
      );

  Widget _shareCoursesNote(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(
          'Nothing here can hold a course? If your Course column is a relation, '
          'Notion hides it until the table it points at is shared too. In '
          'Notion, open the ••• menu on that table, then Connections, and add '
          'Zeolite. Come back and reopen this screen.',
          style: _hint(context),
        ),
      );

  /// The column the app cannot work without, and the one a table built by hand
  /// never has. Offered rather than done quietly: it writes to their schema.
  Widget _addKeyColumnOffer(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _busy ? null : controller.addKeyColumn,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add the Zeolite ID column'),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Adds a text column called Zeolite ID to your table. Until it '
              'exists, syncing is held back rather than writing every class '
              'again on every run. It shows up as a column; hide it in Notion '
              'if it is in your way.',
              style: _hint(context),
            ),
          ],
        ),
      );

  /// Where the Course relation points.
  ///
  /// Only template adoption used to set this, so anyone who reinstalled and
  /// reconnected to their own database — or built the two tables by hand —
  /// had no way to say where their courses live, and the relation was left
  /// empty on every row.
  List<Widget> _coursesSection(BuildContext context) {
    if (form.narrowed) return const <Widget>[];
    final NotionProperty? course = form.fields[NotionField.course];
    if (course?.type != 'relation') return const <Widget>[];

    return <Widget>[
      const SizedBox(height: AppSpacing.lg),
      const SectionHeader('Courses table'),
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(
          'Your Course column is a relation, so Zeolite needs to know which '
          'table it points at to keep a page per subject there.',
          style: _hint(context),
        ),
      ),
      SurfaceCard(
        padding: EdgeInsets.zero,
        child: AppRow(
          icon: Icons.table_chart_outlined,
          title: form.coursesTitle ??
              (form.courses == null ? 'Not linked' : 'Linked'),
          onTap: _busy ? null : () => _pickCourses(context),
        ),
      ),
      if (form.courses == null && form.suggestedCourses != null)
        ..._linkSuggestedOffer(context, form.suggestedCourses!),
    ];
  }

  List<Widget> _linkSuggestedOffer(
    BuildContext context,
    NotionTableChoice choice,
  ) =>
      <Widget>[
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => controller.linkCourses(choice),
          icon: const Icon(Icons.link_rounded, size: 18),
          label: Text('Link ${choice.title}'),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Your Course column points at ${choice.title}. Linking it adds a '
          'text column called Zeolite ID there, so each course page can be '
          'found again.',
          style: _hint(context),
        ),
      ];

  Future<void> _pickCourses(BuildContext context) async {
    // Not [form], which predates the wait.
    final NotionMappingForm now = await controller.ensureSources();
    if (!context.mounted) return;

    final NotionTableChoice? choice =
        await showModalBottomSheet<NotionTableChoice>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final NotionTableChoice option in now.sources)
              if (option.databaseId != now.databaseId)
                ListTile(
                  leading: const Icon(Icons.table_chart_outlined),
                  title: Text(option.title),
                  subtitle: switch (now.placeOf(option)) {
                    final String place => Text(place),
                    null => null,
                  },
                  onTap: () => Navigator.of(context).pop(option),
                ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    await controller.linkCourses(choice);
  }

  Future<void> _save(BuildContext context) async {
    final NavigatorState navigator = Navigator.of(context);
    await controller.save();
    if (context.mounted) navigator.pop();
  }

  List<Widget> sourceList(BuildContext context) {
    if (form.sources.isEmpty && !_busy) {
      return <Widget>[
        const EmptyState(
          icon: Icons.table_chart_outlined,
          title: 'No tables shared',
          message: 'A table you have just made can take a moment to appear. '
              'Try again, or share it with Zeolite in Notion — the page '
              'holding your tables, so every one of them comes along.',
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: TextButton(
            onPressed: controller.lookAgain,
            child: const Text('Look again'),
          ),
        ),
      ];
    }
    return <Widget>[
      // Only the tables actually shared are listed, and a table whose Course
      // column points at one that is not shared reads as having no Course
      // column at all. Saying so here is cheaper than the dead end it causes.
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Text(
          'Missing one? Zeolite only sees what you shared in Notion. If your '
          'classes and courses are two tables, share the page holding both — '
          'or add each table to the connection — or the link between them '
          'cannot be read.',
          style: _hint(context),
        ),
      ),
      for (final NotionTableChoice choice in form.sources) ...<Widget>[
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: AppRow(
            icon: Icons.table_chart_outlined,
            title: choice.title,
            value: form.placeOf(choice),
            onTap: _busy ? null : () => controller.chooseSource(choice),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
      if (form.hasMore) ...<Widget>[
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: _busy ? null : controller.loadSources,
          child: const Text('Show more'),
        ),
      ],
    ];
  }

  List<Widget> fieldForm(BuildContext context) {
    final bool narrowed = form.narrowed;
    final NotionProperty? status = form.fields[NotionField.status];
    final NotionProperty? kind = form.fields[NotionField.kind];
    return <Widget>[
      Text(
        narrowed
            ? 'Your template matched everything Zeolite needs. These are the '
                'rest — map them, or carry on without them.'
            : 'Zeolite filled these in from the column names. Change anything '
                'it guessed wrong.',
        style: TextStyle(color: context.palette.textSecondary),
      ),
      if (!narrowed)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : controller.showSources,
            child: const Text('Use a different table'),
          ),
        ),
      const SizedBox(height: AppSpacing.lg),
      for (final NotionField field in NotionField.values)
        if (!narrowed || form.gapFields!.contains(field)) ...<Widget>[
          _PropertyPicker(
            field: field,
            properties: form.properties,
            chosen: form.fields[field],
            onChanged: (NotionProperty? property) =>
                controller.setField(field, property),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (field == NotionField.key && form.fields[field] == null)
            _addKeyColumnOffer(context),
          if (field == NotionField.course && form.hiddenRelation)
            _shareCoursesNote(context),
        ],
      ..._coursesSection(context),
      if (kind != null &&
          kind.options.isNotEmpty &&
          categories.isNotEmpty &&
          (!narrowed || form.gapKinds!.isNotEmpty)) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('What each class type is called'),
        for (final ClassCategory category in categories)
          if (!narrowed ||
              form.gapKinds!.contains(category.name.toLowerCase())) ...<Widget>[
            _ValuePicker(
              word: category.name.toLowerCase(),
              label: category.name,
              options: kind.options,
              chosen: form.kindValues[category.name.toLowerCase()],
              onChanged: (String? option) => controller.setKindValue(
                category.name.toLowerCase(),
                option,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
      ],
      if (status != null &&
          status.options.isNotEmpty &&
          (!narrowed || form.gapStatus!.isNotEmpty)) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('What each status means'),
        Text(
          LogVerdict.explained,
          style: TextStyle(fontSize: 12, color: context.palette.textTertiary),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final String option in status.options)
          if (!narrowed || form.gapStatus!.contains(option)) ...<Widget>[
            _MeaningPicker(
              option: option,
              chosen: form.statusMeanings[option],
              onChanged: (LogVerdict? meaning) =>
                  controller.setStatusMeaning(option, meaning),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
      ],
      const SizedBox(height: AppSpacing.lg),
      FilledButton(
        onPressed: _busy || !form.complete ? null : () => _save(context),
        child: const Text('Save'),
      ),
      // Only where every gap is optional — adoption guarantees that, but a
      // required field left unmapped still has to be answered.
      if (narrowed &&
          !form.gapFields!.any((NotionField f) => f.isRequired)) ...<Widget>[
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Skip for now'),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Sync works without these. You can map them later from Notion sync '
          'in Settings.',
          style: TextStyle(fontSize: 12, color: context.palette.textTertiary),
        ),
      ],
      if (!form.complete) ...<Widget>[
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Course, Date and Status are needed before anything can be synced.',
          style: TextStyle(fontSize: 12, color: context.palette.textTertiary),
        ),
      ],
    ];
  }
}

/// One Zeolite field and the columns that could hold it.
class _PropertyPicker extends StatelessWidget {
  const _PropertyPicker({
    required this.field,
    required this.properties,
    required this.chosen,
    required this.onChanged,
  });

  final NotionField field;
  final List<NotionProperty> properties;
  final NotionProperty? chosen;
  final ValueChanged<NotionProperty?> onChanged;

  @override
  Widget build(BuildContext context) {
    // Only columns of a type that can hold the value, so a mapping cannot be
    // built that reads fine and fails on every row it pushes.
    final List<NotionProperty> eligible = properties
        .where((NotionProperty p) => field.types.contains(p.type))
        .toList(growable: false);

    // Belt as well as braces: the saved mapping outlives the schema it was
    // built against, and a stale choice must read as unmapped, not throw.
    final bool stillThere =
        eligible.any((NotionProperty p) => p.id == chosen?.id);

    return SurfaceCard(
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  field.isRequired ? '${field.label} *' : field.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  field.description,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: context.palette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: stillThere ? chosen?.id : null,
              hint: Text(
                eligible.isEmpty ? 'No column fits' : 'Not mapped',
                style: TextStyle(color: context.palette.textTertiary),
              ),
              items: <DropdownMenuItem<String>>[
                if (!field.isRequired)
                  const DropdownMenuItem<String>(child: Text('Not mapped')),
                for (final NotionProperty property in eligible)
                  DropdownMenuItem<String>(
                    value: property.id,
                    child: Text(property.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: eligible.isEmpty
                  ? null
                  : (String? id) => onChanged(
                        id == null
                            ? null
                            : eligible.firstWhere(
                                (NotionProperty p) => p.id == id,
                              ),
                      ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One of Zeolite's status words and the option it means in this workspace.
class _ValuePicker extends StatelessWidget {
  const _ValuePicker({
    required this.word,
    required this.options,
    required this.chosen,
    required this.onChanged,
    this.label,
  });

  final String word;

  /// What to show, when it is not just [word] with a capital.
  final String? label;
  final List<String> options;
  final String? chosen;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label ?? '${word[0].toUpperCase()}${word.substring(1)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: chosen,
              hint: Text(
                'Not used',
                style: TextStyle(color: context.palette.textTertiary),
              ),
              items: <DropdownMenuItem<String>>[
                const DropdownMenuItem<String>(child: Text('Not used')),
                for (final String option in options)
                  DropdownMenuItem<String>(
                    value: option,
                    child: Text(option, overflow: TextOverflow.ellipsis),
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

/// One `Status` option and what it means, worded as the class-log screen
/// words it.
class _MeaningPicker extends StatelessWidget {
  const _MeaningPicker({
    required this.option,
    required this.chosen,
    required this.onChanged,
  });

  final String option;
  final LogVerdict? chosen;
  final ValueChanged<LogVerdict?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              option,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: DropdownButton<LogVerdict>(
              isExpanded: true,
              value: chosen,
              hint: Text(
                'Choose',
                style: TextStyle(color: context.palette.textTertiary),
              ),
              items: <DropdownMenuItem<LogVerdict>>[
                for (final LogVerdict verdict in LogVerdict.values)
                  DropdownMenuItem<LogVerdict>(
                    value: verdict,
                    child: Text(
                      verdict.labelFor(option),
                      overflow: TextOverflow.ellipsis,
                    ),
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
