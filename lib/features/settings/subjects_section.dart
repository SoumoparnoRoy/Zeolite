import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../core/words.dart';
import '../../data/models/class_category.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/class_log.dart';
import '../../domain/class_weight.dart';
import '../../domain/notion_export.dart';
import '../../services/class_log_mapping_store.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/undo_snack.dart';
import '../subjects/class_editor_sheets.dart';
import '../subjects/class_log_mapping_screen.dart';
import '../subjects/notion_import_screen.dart';
import '../subjects/subjects_screen.dart';
import '../timetable/import_screen.dart';

import 'settings_rows.dart';

class SubjectsSection extends ConsumerWidget {
  const SubjectsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TimetableData? timetable = ref.watch(timetableProvider).value;
    final List<Subject> subjects = timetable?.subjects ?? <Subject>[];
    final int classCount =
        (timetable?.slots.length ?? 0) + (timetable?.extras.length ?? 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('Subjects'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: SettingsRow(
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
          child: SettingsRow(
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
          child: SettingsRow(
            icon: Icons.history_rounded,
            title: 'Import a class log',
            value: 'A spreadsheet or Notion export of what you attended',
            onTap: () => _importNotionLog(context, ref),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        const SettingsHint(
          'Add subjects, change their colour or attendance target, and '
          'delete ones you have dropped.',
        ),
      ],
    );
  }

  /// Reads the file and hands it to the preview, which owns the writing — the
  /// same split the portal page's import uses.
  ///
  /// A file that explains itself — a template export, or a layout read once
  /// before — goes straight to the preview; anything else is matched first.
  Future<void> _importNotionLog(BuildContext context, WidgetRef ref) async {
    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a class log (CSV or Notion export)',
    );
    if (picked == null || !context.mounted) return;

    final ClassLogTable? table = ClassLogTable.of(await picked.readAsBytes());
    if (!context.mounted) return;
    if (table == null) {
      _say(context, 'No rows could be found in that file. It needs to be a '
          'CSV, or a Notion export holding one.');
      return;
    }

    final ClassLogMappingStore store = ClassLogMappingStore();
    ClassLogMapping? mapping =
        ((await store.load(table)) ?? ClassLogMapping.guess(table))
            .withGuessedWords(table);
    if (!context.mounted) return;

    Future<ClassLogMapping?> ask(ClassLogMapping from) =>
        Navigator.of(context).push<ClassLogMapping>(
          MaterialPageRoute<ClassLogMapping>(
            settings: const RouteSettings(name: 'class_log_mapping'),
            builder: (BuildContext context) =>
                ClassLogMappingScreen(table: table, initial: from),
          ),
        );

    if (!mapping.readyFor(table)) {
      mapping = await ask(mapping);
      if (mapping == null || !context.mounted) return;
    }
    await store.save(table, mapping);

    final NotionExport export = readClassLog(table, mapping);
    if (!context.mounted) return;
    if (export.isEmpty) {
      _say(
        context,
        <String>[...export.problems, ...export.leftOut].firstOrNull ??
            'No classes could be read out of that file.',
      );
      return;
    }

    ClassLogMapping current = mapping;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'notion_import'),
        builder: (BuildContext context) => NotionImportScreen(
          export: export,
          title: 'Classes from the file',
          remap: () async {
            final ClassLogMapping? changed = await ask(current);
            if (changed == null) return null;
            current = changed;
            await store.save(table, changed);
            return readClassLog(table, changed);
          },
        ),
      ),
    );
  }

  void _say(BuildContext context, String message) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
      );
}

class CategoriesSection extends ConsumerWidget {
  const CategoriesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings =
        ref.watch(settingsProvider).value ?? const AppSettings();
    final SettingsController controller = ref.read(settingsProvider.notifier);
    final TimetableData? timetable = ref.watch(timetableProvider).value;
    final List<ClassCategory> categories =
        timetable?.categories ?? <ClassCategory>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
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
            child: SettingsHint(
              'No categories yet. Create one — Lecture, Practical, Tutorial — '
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
                  SettingsRow(
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
                const SettingsHint(
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
              const SettingsHint(
                'Used for subjects that are not in a category. Setting a '
                'class start time fills the end time in from this.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _deleteCategory(
    BuildContext context,
    WidgetRef ref,
    ClassCategory category,
  ) async {
    final int? id = category.id;
    if (id == null) return;

    final int inUse =
        await ref.read(subjectActionsProvider).countSubjectsInCategory(id);
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
    await ref.read(subjectActionsProvider).deleteCategory(id);
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
    final ActionCore core = ref.read(actionCoreProvider);
    final ImportActions imports = ref.read(importActionsProvider);
    final int changed = await imports.applyClassWeights();
    showUndoSnack(
      messenger,
      core,
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
    final int held =
        subjects.where((Subject s) => s.categoryId == category.id).length;
    return <String>[
      held == 1 ? '1 subject' : '$held subjects',
      'defaults to ${category.durationLabel}',
      if (category.weight != 1)
        'counts as ${classWeightLabel(category.weight).toLowerCase()}',
    ].join(' · ');
  }
}
