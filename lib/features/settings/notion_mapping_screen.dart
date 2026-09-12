import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../data/models/class_category.dart';
import '../../state/providers.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../domain/sync/sync_target.dart';
import '../../services/notion/notion_client.dart';
import '../../state/notion_providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// Choosing where attendance is filed in Notion, and which column holds what.
///
/// Three stages in one route rather than three pushes: picking a database and
/// then a column inside it is one decision the user is making, and a back
/// stack through it would let them leave half a mapping behind.
class NotionMappingScreen extends ConsumerStatefulWidget {
  const NotionMappingScreen({super.key, this.onlyUnmapped = false});

  /// Shows only what a template did not match, with a way past it. The whole
  /// form would bury two gaps among ten rows that are already right.
  final bool onlyUnmapped;

  @override
  ConsumerState<NotionMappingScreen> createState() =>
      _NotionMappingScreenState();
}

enum _Stage { loading, sources, fields }

class _NotionMappingScreenState extends ConsumerState<NotionMappingScreen> {
  _Stage _stage = _Stage.loading;
  String? _error;
  bool _busy = false;

  final List<_Choice> _sources = <_Choice>[];
  String? _cursor;
  bool _hasMore = false;
  int _retries = 0;
  Timer? _retry;

  String _databaseId = '';
  String _databaseTitle = '';
  String _dataSourceId = '';

  List<NotionProperty> _properties = const <NotionProperty>[];
  Map<NotionField, NotionProperty> _fields = <NotionField, NotionProperty>{};
  Map<String, String> _statusValues = <String, String>{};
  Map<String, String> _kindValues = <String, String>{};
  NotionCourses? _courses;

  /// Shown next to the link. [NotionCourses] holds ids, not a name, and a
  /// table identified only by an id is not something anyone can check.
  String? _coursesTitle;

  /// Saved from, not rebuilt, so a field this screen does not edit survives.
  NotionMapping? _loaded;

  /// What was unmapped when this opened. Captured once, not recomputed: a row
  /// that vanished the moment you answered it would leave no way to change it.
  Set<NotionField>? _gapFields;
  Set<String>? _gapStatus;
  Set<String>? _gapKinds;

  bool get _narrowed => widget.onlyUnmapped && _gapFields != null;

  List<ClassCategory> get _categories =>
      ref.read(timetableProvider).value?.categories ?? const <ClassCategory>[];

  @override
  void initState() {
    super.initState();
    _open();
  }

  NotionClient get _client => ref.read(notionClientProvider);

  /// An existing mapping reopens on its own columns, so Change is an edit
  /// rather than starting again from the database list.
  Future<void> _open() async {
    final NotionMapping? existing = await ref.read(notionMappingProvider.future);
    if (!mounted) return;
    if (existing == null) {
      await _loadSources();
      return;
    }
    _databaseId = existing.databaseId;
    _databaseTitle = existing.title;
    _fields = Map<NotionField, NotionProperty>.from(existing.fields);
    _statusValues = Map<String, String>.from(existing.statusValues);
    _kindValues = Map<String, String>.from(existing.kindValues);
    // Carried, not rebuilt: saving without it would drop the dashboard.
    _courses = existing.courses;
    _loaded = existing;
    await _loadSchema(existing.dataSourceId, keepChoices: true);
  }

  /// Search answers with tables, not databases — since 2025-09-03 a database
  /// is only a container — so the one question worth asking is which table,
  /// and it is asked once instead of twice.
  Future<void> _loadSources() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final NotionResult result = await _client.searchDataSources(cursor: _cursor);
    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _busy = false;
        _stage = _Stage.sources;
        _error = _messageFor(result);
      });
      return;
    }

    final Object? results = result.body?['results'];
    setState(() {
      _busy = false;
      _stage = _Stage.sources;
      if (results is List<Object?>) {
        for (final Object? row in results) {
          if (row is! Map<String, Object?>) continue;
          final String? id = row['id'] as String?;
          if (id == null) continue;
          _sources.add(
            _Choice(
              id,
              notionTitleOf(row) ?? 'Untitled',
              _parentDatabaseOf(row) ?? '',
            ),
          );
        }
      }
      _hasMore = result.body?['has_more'] == true;
      _cursor = result.body?['next_cursor'] as String?;
    });

    // Notion's search index lags a write, so "No tables shared" is a wrong
    // answer, not a slow one. A timer, so `dispose` can cancel it.
    if (_sources.isEmpty && !_hasMore && _retries < _searchRetries) {
      _retries++;
      _retry?.cancel();
      _retry = Timer(_searchBackoff * _retries, () {
        if (mounted) _loadSources();
      });
    }
  }

  static const int _searchRetries = 3;
  static const Duration _searchBackoff = Duration(seconds: 1);

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _lookAgain() async {
    _retry?.cancel();
    setState(() {
      _sources.clear();
      _cursor = null;
      _retries = 0;
    });
    await _loadSources();
  }

  static String? _parentDatabaseOf(Map<String, Object?> source) {
    final Object? parent = source['parent'];
    return parent is Map<String, Object?>
        ? parent['database_id'] as String?
        : null;
  }

  Future<void> _chooseSource(_Choice choice) async {
    // Another database relates into its own Courses table, if any at all.
    final bool moved = choice.databaseId != _databaseId;
    setState(() {
      _databaseId = choice.databaseId;
      _databaseTitle = choice.title;
      if (moved) {
        _courses = null;
        _coursesTitle = null;
        _loaded = null;
      }
    });
    await _loadSchema(choice.id);
  }

  Future<void> _loadSchema(String dataSourceId, {bool keepChoices = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final NotionResult result = await _client.dataSource(dataSourceId);
    if (!mounted) return;
    if (!result.ok || result.body == null) {
      setState(() {
        _busy = false;
        _stage = _Stage.fields;
        _error = _messageFor(result);
      });
      return;
    }

    final List<NotionProperty> properties = notionPropertiesOf(result.body!);
    final NotionMapping guess = NotionMapping.match(
      databaseId: _databaseId,
      dataSourceId: dataSourceId,
      title: _databaseTitle,
      properties: properties,
      categoryNames: _categories.map((ClassCategory c) => c.name).toList(),
    );

    setState(() {
      _busy = false;
      _stage = _Stage.fields;
      _dataSourceId = dataSourceId;
      _properties = properties;
      // Reopening keeps every answer already given and lets the guess fill
      // only the gaps, so a column added since — to the database or to the
      // app — is offered instead of staying invisible behind an old mapping.
      // A column deleted in Notion since is dropped rather than kept: a choice
      // pointing at a property that no longer exists leaves the dropdown with
      // a value that is not among its items, which throws instead of drawing.
      final Set<String> live = <String>{
        for (final NotionProperty p in properties) p.id,
      };
      _fields = <NotionField, NotionProperty>{
        ...guess.fields,
        if (keepChoices)
          for (final MapEntry<NotionField, NotionProperty> e in _fields.entries)
            if (live.contains(e.value.id)) e.key: e.value,
      };
      _statusValues = <String, String>{
        ...guess.statusValues,
        if (keepChoices) ..._statusValues,
      };
      _kindValues = <String, String>{
        ...guess.kindValues,
        if (keepChoices) ..._kindValues,
      };
      if (widget.onlyUnmapped) _captureGaps();
    });
  }

  /// Notion leaves a relation out of the schema altogether when the table it
  /// points at is not shared with the connection, so the column the person can
  /// see in their own database is simply not there to map. Without saying so,
  /// the screen just refuses to finish and never explains why.
  bool get _hiddenRelation =>
      _fields[NotionField.course] == null &&
      !_properties.any((NotionProperty p) => p.type == 'relation');

  Widget _shareCoursesNote(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(
          'Nothing here can hold a course? If your Course column is a relation, '
          'Notion hides it until the table it points at is shared too. In '
          'Notion, open the ••• menu on that table, then Connections, and add '
          'Zeolite. Come back and reopen this screen.',
          style: TextStyle(
            fontSize: 12,
            height: 1.3,
            color: context.palette.textTertiary,
          ),
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
              onPressed: _busy ? null : _addKeyColumn,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add the Zeolite ID column'),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Adds a text column called Zeolite ID to your table. Until it '
              'exists, syncing is held back rather than writing every class '
              'again on every run. It shows up as a column; hide it in Notion '
              'if it is in your way.',
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: context.palette.textTertiary,
              ),
            ),
          ],
        ),
      );

  Future<void> _addKeyColumn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final NotionResult result = await _client.addProperty(
      _dataSourceId,
      name: NotionField.key.label,
      type: 'rich_text',
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = _messageFor(result);
      });
      return;
    }
    // Re-read rather than assume: the reload's own guess is what maps the new
    // column, and it is also what proves Notion made it.
    await _loadSchema(_dataSourceId, keepChoices: true);
  }

  /// Where the Course relation points.
  ///
  /// Only template adoption used to set this, so anyone who reinstalled and
  /// reconnected to their own database — or built the two tables by hand —
  /// had no way to say where their courses live, and the relation was left
  /// empty on every row.
  List<Widget> _coursesSection(BuildContext context) {
    if (_narrowed) return const <Widget>[];
    final NotionProperty? course = _fields[NotionField.course];
    if (course?.type != 'relation') return const <Widget>[];

    return <Widget>[
      const SizedBox(height: AppSpacing.lg),
      const SectionHeader('Courses table'),
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(
          'Your Course column is a relation, so Zeolite needs to know which '
          'table it points at to keep a page per subject there.',
          style: TextStyle(
            fontSize: 12,
            height: 1.3,
            color: context.palette.textTertiary,
          ),
        ),
      ),
      SurfaceCard(
        padding: EdgeInsets.zero,
        child: AppRow(
          icon: Icons.table_chart_outlined,
          title: _coursesTitle ?? (_courses == null ? 'Not linked' : 'Linked'),
          onTap: _busy ? null : _pickCourses,
        ),
      ),
    ];
  }

  Future<void> _pickCourses() async {
    final _Choice? choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final _Choice option in _sources)
              if (option.databaseId != _databaseId)
                ListTile(
                  leading: const Icon(Icons.table_chart_outlined),
                  title: Text(option.title),
                  onTap: () => Navigator.of(context).pop(option),
                ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _linkCourses(choice);
  }

  Future<void> _linkCourses(_Choice choice) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final NotionResult result = await _client.dataSource(choice.id);
    if (!mounted) return;
    if (!result.ok || result.body == null) {
      setState(() {
        _busy = false;
        _error = _messageFor(result);
      });
      return;
    }

    final NotionCourses courses = NotionCourses.match(
      databaseId: choice.databaseId,
      dataSourceId: choice.id,
      properties: notionPropertiesOf(result.body!),
    );
    if (!courses.isComplete) {
      // Almost always the same missing column as on the attendance table, and
      // the same answer: a page nothing can find again is written twice.
      final NotionResult added = await _client.addProperty(
        choice.id,
        name: NotionField.key.label,
        type: 'rich_text',
      );
      if (!mounted) return;
      if (!added.ok) {
        setState(() {
          _busy = false;
          _error = _messageFor(added);
        });
        return;
      }
      await _linkCoursesAgain(choice);
      return;
    }

    setState(() {
      _busy = false;
      _courses = courses;
      _coursesTitle = choice.title;
    });
  }

  /// One retry only, after the column was added. A table still incomplete has
  /// no title column either, which is not something this screen can fix.
  Future<void> _linkCoursesAgain(_Choice choice) async {
    final NotionResult result = await _client.dataSource(choice.id);
    if (!mounted) return;
    final NotionCourses courses = result.body == null
        ? NotionCourses.match(
            databaseId: choice.databaseId,
            dataSourceId: choice.id,
            properties: const <NotionProperty>[],
          )
        : NotionCourses.match(
            databaseId: choice.databaseId,
            dataSourceId: choice.id,
            properties: notionPropertiesOf(result.body!),
          );
    setState(() {
      _busy = false;
      if (courses.isComplete) {
        _courses = courses;
        _coursesTitle = choice.title;
      } else {
        _error = 'That table needs a title column and a Zeolite ID column '
            'before courses can be kept in it.';
      }
    });
  }

  void _captureGaps() {
    _gapFields = <NotionField>{
      for (final NotionField field in NotionField.values)
        if (!_fields.containsKey(field)) field,
    };
    _gapStatus = <String>{
      if (_fields.containsKey(NotionField.status))
        for (final String word in kNotionStatusValues)
          if (!_statusValues.containsKey(word)) word,
    };
    _gapKinds = <String>{
      if (_fields.containsKey(NotionField.kind))
        for (final ClassCategory category in _categories)
          if (!_kindValues.containsKey(category.name.toLowerCase()))
            category.name.toLowerCase(),
    };
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final NavigatorState navigator = Navigator.of(context);
    final NotionMapping base = _loaded?.databaseId == _databaseId
        ? _loaded!
        : NotionMapping(
            databaseId: _databaseId,
            dataSourceId: _dataSourceId,
            title: _databaseTitle,
            fields: const <NotionField, NotionProperty>{},
          );

    await ref.read(notionMappingProvider.notifier).save(
          base.copyWith(
            dataSourceId: _dataSourceId,
            title: _databaseTitle,
            fields: _fields,
            statusValues: _statusValues,
            kindValues: _kindValues,
            courses: _courses,
          ),
        );
    if (mounted) navigator.pop();
  }

  /// Told apart because the fixes are different: sharing a page, reconnecting,
  /// or simply waiting. One message for all three sends the user to the wrong
  /// one of the three.
  static String _messageFor(NotionResult result) {
    if (result.message == 'object_not_found') {
      return 'Zeolite cannot see that table. Share it with the connection in '
          'Notion, then try again.';
    }
    return switch (result.failure) {
      SyncFailure.auth =>
        'Zeolite is not allowed to read your workspace any more. Disconnect '
            'Notion and connect it again.',
      SyncFailure.offline =>
        'Could not reach Notion. Check your network and try again.',
      SyncFailure.rateLimited => 'Notion is busy. Wait a moment and try again.',
      _ => 'Notion refused that request. Reconnect Notion and try again.',
    };
  }

  bool get _complete => NotionField.values
      .where((NotionField f) => f.isRequired)
      .every(_fields.containsKey);

  @override
  Widget build(BuildContext context) {
    return PushScaffold(
      title: 'Notion database',
      subtitle: switch (_stage) {
        _Stage.sources => 'Where should attendance go?',
        _ => _databaseTitle.isEmpty ? null : _databaseTitle,
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
                if (_error != null) ...<Widget>[
                  Text(_error!, style: TextStyle(color: context.palette.absent)),
                  const SizedBox(height: AppSpacing.lg),
                ],
                ..._stageBody(context),
                if (_busy) ...<Widget>[
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

  List<Widget> _stageBody(BuildContext context) => switch (_stage) {
        _Stage.loading => const <Widget>[],
        _Stage.sources => _sourceList(context),
        _Stage.fields => _fieldForm(context),
      };

  List<Widget> _sourceList(BuildContext context) {
    if (_sources.isEmpty && !_busy) {
      return <Widget>[
        const EmptyState(
          icon: Icons.table_chart_outlined,
          title: 'No tables shared',
          message: 'A database you have just made can take a moment to appear. '
              'Try again, or share it with Zeolite in Notion — the page '
              'holding your tables, so every one of them comes along.',
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: TextButton(
            onPressed: _lookAgain,
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
          style: TextStyle(
            fontSize: 12,
            height: 1.3,
            color: context.palette.textTertiary,
          ),
        ),
      ),
      for (final _Choice choice in _sources) ...<Widget>[
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: AppRow(
            icon: Icons.table_chart_outlined,
            title: choice.title,
            onTap: _busy ? null : () => _chooseSource(choice),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
      if (_hasMore) ...<Widget>[
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: _busy ? null : _loadSources,
          child: const Text('Show more'),
        ),
      ],
    ];
  }

  List<Widget> _fieldForm(BuildContext context) {
    final NotionProperty? status = _fields[NotionField.status];
    final NotionProperty? kind = _fields[NotionField.kind];
    return <Widget>[
      Text(
        _narrowed
            ? 'Your template matched everything Zeolite needs. These are the '
                'rest — map them, or carry on without them.'
            : 'Zeolite filled these in from the column names. Change anything '
                'it guessed wrong.',
        style: TextStyle(color: context.palette.textSecondary),
      ),
      const SizedBox(height: AppSpacing.lg),
      for (final NotionField field in NotionField.values)
        if (!_narrowed || _gapFields!.contains(field)) ...<Widget>[
        _PropertyPicker(
          field: field,
          properties: _properties,
          chosen: _fields[field],
          onChanged: (NotionProperty? property) => setState(() {
            if (property == null) {
              _fields.remove(field);
            } else {
              _fields[field] = property;
            }
            // The words belong to the column, so a different Status column
            // leaves the old workspace's spellings behind.
            if (field == NotionField.status) _statusValues = <String, String>{};
            if (field == NotionField.kind) _kindValues = <String, String>{};
          }),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (field == NotionField.key && _fields[field] == null)
          _addKeyColumnOffer(context),
        if (field == NotionField.course && _hiddenRelation)
          _shareCoursesNote(context),
      ],
      ..._coursesSection(context),
      if (kind != null &&
          kind.options.isNotEmpty &&
          _categories.isNotEmpty &&
          (!_narrowed || _gapKinds!.isNotEmpty)) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('What each class type is called'),
        for (final ClassCategory category in _categories)
          if (!_narrowed || _gapKinds!.contains(category.name.toLowerCase()))
            ...<Widget>[
          _ValuePicker(
            word: category.name.toLowerCase(),
            label: category.name,
            options: kind.options,
            chosen: _kindValues[category.name.toLowerCase()],
            onChanged: (String? option) => setState(() {
              if (option == null) {
                _kindValues.remove(category.name.toLowerCase());
              } else {
                _kindValues[category.name.toLowerCase()] = option;
              }
            }),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
      if (status != null &&
          status.options.isNotEmpty &&
          (!_narrowed || _gapStatus!.isNotEmpty)) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('What each status is called'),
        for (final String word in kNotionStatusValues)
          if (!_narrowed || _gapStatus!.contains(word)) ...<Widget>[
          _ValuePicker(
            word: word,
            options: status.options,
            chosen: _statusValues[word],
            onChanged: (String? option) => setState(() {
              if (option == null) {
                _statusValues.remove(word);
              } else {
                _statusValues[word] = option;
              }
            }),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
      const SizedBox(height: AppSpacing.lg),
      FilledButton(
        onPressed: _busy || !_complete ? null : _save,
        child: const Text('Save'),
      ),
      // Only where every gap is optional — adoption guarantees that, but a
      // required field left unmapped still has to be answered.
      if (_narrowed && !_gapFields!.any((NotionField f) => f.isRequired))
        ...<Widget>[
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
      if (!_complete) ...<Widget>[
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Course, Date and Status are needed before anything can be synced.',
          style: TextStyle(fontSize: 12, color: context.palette.textTertiary),
        ),
      ],
    ];
  }
}

@immutable
class _Choice {
  const _Choice(this.id, this.title, this.databaseId);

  final String id;
  final String title;

  /// Kept only so the mapping records where the table lives; every call is
  /// made against the table itself.
  final String databaseId;
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
