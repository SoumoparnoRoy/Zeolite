import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
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
  const NotionMappingScreen({super.key});

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

  String _databaseId = '';
  String _databaseTitle = '';
  String _dataSourceId = '';

  List<NotionProperty> _properties = const <NotionProperty>[];
  Map<NotionField, NotionProperty> _fields = <NotionField, NotionProperty>{};
  Map<String, String> _statusValues = <String, String>{};

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
  }

  static String? _parentDatabaseOf(Map<String, Object?> source) {
    final Object? parent = source['parent'];
    return parent is Map<String, Object?>
        ? parent['database_id'] as String?
        : null;
  }

  Future<void> _chooseSource(_Choice choice) async {
    setState(() {
      _databaseId = choice.databaseId;
      _databaseTitle = choice.title;
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
    );

    setState(() {
      _busy = false;
      _stage = _Stage.fields;
      _dataSourceId = dataSourceId;
      _properties = properties;
      // Reopening keeps what the user already answered; a fresh database has
      // nothing to keep and takes the guess.
      if (!keepChoices) {
        _fields = Map<NotionField, NotionProperty>.from(guess.fields);
        _statusValues = Map<String, String>.from(guess.statusValues);
      }
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final NavigatorState navigator = Navigator.of(context);
    await ref.read(notionMappingProvider.notifier).save(
          NotionMapping(
            databaseId: _databaseId,
            dataSourceId: _dataSourceId,
            title: _databaseTitle,
            fields: _fields,
            statusValues: _statusValues,
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
          message: 'Open Notion and share a database with Zeolite, or '
              'reconnect and take the template.',
        ),
      ];
    }
    return <Widget>[
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
    return <Widget>[
      Text(
        'Zeolite filled these in from the column names. Change anything it '
        'guessed wrong.',
        style: TextStyle(color: context.palette.textSecondary),
      ),
      const SizedBox(height: AppSpacing.lg),
      for (final NotionField field in NotionField.values) ...<Widget>[
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
          }),
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
      if (status != null && status.options.isNotEmpty) ...<Widget>[
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('What each status is called'),
        for (final String word in kNotionStatusValues) ...<Widget>[
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

    return SurfaceCard(
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              field.isRequired ? '${field.label} *' : field.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: chosen?.id,
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
  });

  final String word;
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
              '${word[0].toUpperCase()}${word.substring(1)}',
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
