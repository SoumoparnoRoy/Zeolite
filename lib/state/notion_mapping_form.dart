import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/class_category.dart';
import '../domain/notion/notion_mapping.dart';
import '../domain/sync/sync_target.dart';
import '../services/notion/notion_client.dart';
import '../services/notion/notion_places.dart';
import 'app_providers.dart';
import 'notion_providers.dart';

enum NotionMappingStage { loading, sources, fields }

/// A table offered for attendance or courses.
@immutable
class NotionTableChoice {
  const NotionTableChoice(this.id, this.title, this.databaseId);

  final String id;
  final String title;

  /// Kept only so the mapping records where the table lives; every call is
  /// made against the table itself.
  final String databaseId;
}

/// Everything the Notion table screen shows while a mapping is being chosen.
@immutable
class NotionMappingForm {
  const NotionMappingForm({
    this.stage = NotionMappingStage.loading,
    this.error,
    this.busy = false,
    this.sources = const <NotionTableChoice>[],
    this.places = const <String, String>{},
    this.hasMore = false,
    this.databaseId = '',
    this.databaseTitle = '',
    this.dataSourceId = '',
    this.properties = const <NotionProperty>[],
    this.fields = const <NotionField, NotionProperty>{},
    this.statusMeanings = const <String, LogVerdict>{},
    this.kindValues = const <String, String>{},
    this.courses,
    this.coursesTitle,
    this.suggestedCourses,
    this.gapFields,
    this.gapStatus,
    this.gapKinds,
  });

  final NotionMappingStage stage;
  final String? error;
  final bool busy;
  final List<NotionTableChoice> sources;

  /// The page each database sits in, by database id, once it has been found.
  final Map<String, String> places;
  final bool hasMore;

  final String databaseId;
  final String databaseTitle;
  final String dataSourceId;
  final List<NotionProperty> properties;
  final Map<NotionField, NotionProperty> fields;
  final Map<String, LogVerdict> statusMeanings;
  final Map<String, String> kindValues;
  final NotionCourses? courses;

  /// Shown next to the link. [NotionCourses] holds ids, not a name, and a
  /// table identified only by an id is not something anyone can check.
  final String? coursesTitle;

  /// Linking this one would add a column to it, which waits for a tap rather
  /// than happening by itself.
  final NotionTableChoice? suggestedCourses;

  /// What was unmapped when the table was read. Captured, not recomputed: a
  /// row that vanished the moment you answered it would leave no way to
  /// change it. Null unless the screen was opened on the gaps.
  final Set<NotionField>? gapFields;
  final Set<String>? gapStatus;
  final Set<String>? gapKinds;

  bool get narrowed => gapFields != null;

  bool get complete => NotionField.values
      .where((NotionField f) => f.isRequired)
      .every(fields.containsKey);

  /// Notion leaves a relation out of the schema altogether when the table it
  /// points at is not shared with the connection, so the column the person can
  /// see in their own database is simply not there to map. Without saying so,
  /// the screen just refuses to finish and never explains why.
  bool get hiddenRelation =>
      fields[NotionField.course] == null &&
      !properties.any((NotionProperty p) => p.type == 'relation');

  String? placeOf(NotionTableChoice choice) {
    final String? page = places[choice.databaseId];
    return page == null ? null : 'In $page';
  }

  NotionMappingForm copyWith({
    NotionMappingStage? stage,
    Object? error = _keep,
    bool? busy,
    List<NotionTableChoice>? sources,
    Map<String, String>? places,
    bool? hasMore,
    String? databaseId,
    String? databaseTitle,
    String? dataSourceId,
    List<NotionProperty>? properties,
    Map<NotionField, NotionProperty>? fields,
    Map<String, LogVerdict>? statusMeanings,
    Map<String, String>? kindValues,
    Object? courses = _keep,
    Object? coursesTitle = _keep,
    Object? suggestedCourses = _keep,
    Set<NotionField>? gapFields,
    Set<String>? gapStatus,
    Set<String>? gapKinds,
  }) {
    return NotionMappingForm(
      stage: stage ?? this.stage,
      error: identical(error, _keep) ? this.error : error as String?,
      busy: busy ?? this.busy,
      sources: sources ?? this.sources,
      places: places ?? this.places,
      hasMore: hasMore ?? this.hasMore,
      databaseId: databaseId ?? this.databaseId,
      databaseTitle: databaseTitle ?? this.databaseTitle,
      dataSourceId: dataSourceId ?? this.dataSourceId,
      properties: properties ?? this.properties,
      fields: fields ?? this.fields,
      statusMeanings: statusMeanings ?? this.statusMeanings,
      kindValues: kindValues ?? this.kindValues,
      courses:
          identical(courses, _keep) ? this.courses : courses as NotionCourses?,
      coursesTitle: identical(coursesTitle, _keep)
          ? this.coursesTitle
          : coursesTitle as String?,
      suggestedCourses: identical(suggestedCourses, _keep)
          ? this.suggestedCourses
          : suggestedCourses as NotionTableChoice?,
      gapFields: gapFields ?? this.gapFields,
      gapStatus: gapStatus ?? this.gapStatus,
      gapKinds: gapKinds ?? this.gapKinds,
    );
  }
}

/// Lets [NotionMappingForm.copyWith] tell "leave it" from "set it to null".
const Object _keep = Object();

/// One per open screen, keyed on whether it was opened on the gaps only.
final notionMappingFormProvider = NotifierProvider.autoDispose
    .family<NotionMappingFormController, NotionMappingForm, bool>(
  NotionMappingFormController.new,
);

/// Choosing where attendance is filed in Notion, and which column holds what.
class NotionMappingFormController extends Notifier<NotionMappingForm> {
  NotionMappingFormController(this.onlyUnmapped);

  /// Shows only what a template did not match, with a way past it.
  final bool onlyUnmapped;

  late final NotionPlaces _lookup = NotionPlaces(_client);
  final Set<String> _placesAsked = <String>{};
  String? _cursor;
  int _retries = 0;
  Timer? _retry;

  /// Saved from, not rebuilt, so a field the screen does not edit survives.
  NotionMapping? _loaded;

  static const int _searchRetries = 3;
  static const Duration _searchBackoff = Duration(seconds: 1);

  NotionClient get _client => ref.read(notionClientProvider);

  List<ClassCategory> get categories =>
      ref.read(timetableProvider).value?.categories ?? const <ClassCategory>[];

  @override
  NotionMappingForm build() {
    ref.onDispose(() => _retry?.cancel());
    // After build, because the first thing it does is set state.
    scheduleMicrotask(() => unawaited(_open()));
    return const NotionMappingForm();
  }

  /// An existing mapping reopens on its own columns, so Change is an edit
  /// rather than starting again from the database list.
  Future<void> _open() async {
    final NotionMapping? existing =
        await ref.read(notionMappingProvider.future);
    if (!ref.mounted) return;
    if (existing == null) {
      await loadSources();
      return;
    }
    _loaded = existing;
    state = state.copyWith(
      databaseId: existing.databaseId,
      databaseTitle: existing.title,
      fields: Map<NotionField, NotionProperty>.of(existing.fields),
      statusMeanings: Map<String, LogVerdict>.of(existing.statusMeanings),
      kindValues: Map<String, String>.of(existing.kindValues),
      // Carried, not rebuilt: saving without it would drop the dashboard.
      courses: existing.courses,
    );
    await _loadSchema(existing.dataSourceId, keepChoices: true);
  }

  /// Search answers with tables, not databases — since 2025-09-03 a database
  /// is only a container — so the one question worth asking is which table,
  /// and it is asked once instead of twice.
  Future<void> loadSources() async {
    state = state.copyWith(busy: true, error: null);
    final NotionResult result =
        await _client.searchDataSources(cursor: _cursor);
    if (!ref.mounted) return;

    if (!result.ok) {
      state = state.copyWith(
        busy: false,
        stage: NotionMappingStage.sources,
        error: _messageFor(result),
      );
      return;
    }

    final Object? results = result.body?['results'];
    final List<NotionTableChoice> sources = <NotionTableChoice>[
      ...state.sources,
      if (results is List<Object?>)
        for (final Object? row in results)
          if (row is Map<String, Object?> && row['id'] is String)
            NotionTableChoice(
              row['id']! as String,
              notionTitleOf(row) ?? 'Untitled',
              _parentDatabaseOf(row) ?? '',
            ),
    ];
    _cursor = result.body?['next_cursor'] as String?;
    state = state.copyWith(
      busy: false,
      stage: NotionMappingStage.sources,
      sources: sources,
      hasMore: result.body?['has_more'] == true,
    );
    unawaited(_findPlaces());

    // Notion's search index lags a write, so "No tables shared" is a wrong
    // answer, not a slow one. A timer, so disposal can cancel it.
    if (sources.isEmpty && !state.hasMore && _retries < _searchRetries) {
      _retries++;
      _retry?.cancel();
      _retry = Timer(_searchBackoff * _retries, () {
        if (ref.mounted) unawaited(loadSources());
      });
    }
  }

  /// One at a time, since the client already spaces its calls to Notion's
  /// rate limit and the list is readable before any of this lands.
  Future<void> _findPlaces() async {
    for (final NotionTableChoice choice in state.sources) {
      final String id = choice.databaseId;
      if (id.isEmpty || !_placesAsked.add(id)) continue;
      final String? page = await _lookup.pageTitleOf(id);
      if (!ref.mounted) return;
      if (page != null) {
        state = state.copyWith(
          places: <String, String>{...state.places, id: page},
        );
      }
    }
  }

  Future<void> lookAgain() async {
    _retry?.cancel();
    _cursor = null;
    _retries = 0;
    state = state.copyWith(sources: const <NotionTableChoice>[]);
    await loadSources();
  }

  static String? _parentDatabaseOf(Map<String, Object?> source) {
    final Object? parent = source['parent'];
    return parent is Map<String, Object?>
        ? parent['database_id'] as String?
        : null;
  }

  Future<void> chooseSource(NotionTableChoice choice) async {
    // Another database relates into its own Courses table, if any at all.
    final bool moved = choice.databaseId != state.databaseId;
    if (moved) _loaded = null;
    state = moved
        ? state.copyWith(
            databaseId: choice.databaseId,
            databaseTitle: choice.title,
            courses: null,
            coursesTitle: null,
            suggestedCourses: null,
          )
        : state.copyWith(
            databaseId: choice.databaseId,
            databaseTitle: choice.title,
          );
    // Re-picking the open table is backing out, so its answers stay.
    await _loadSchema(choice.id, keepChoices: !moved);
  }

  /// Otherwise a saved mapping could only move by disconnecting Notion.
  Future<void> showSources() async {
    state = state.copyWith(stage: NotionMappingStage.sources);
    if (state.sources.isEmpty) await loadSources();
  }

  /// Reopening an existing mapping lands straight on the fields, so the table
  /// list has never been fetched and there would be nothing to pick from.
  Future<NotionMappingForm> ensureSources() async {
    if (state.sources.isNotEmpty) return state;
    await loadSources();
    if (ref.mounted) state = state.copyWith(stage: NotionMappingStage.fields);
    return state;
  }

  Future<void> _loadSchema(
    String dataSourceId, {
    bool keepChoices = false,
  }) async {
    state = state.copyWith(busy: true, error: null);

    final NotionResult result = await _client.dataSource(dataSourceId);
    if (!ref.mounted) return;
    if (!result.ok || result.body == null) {
      state = state.copyWith(
        busy: false,
        stage: NotionMappingStage.fields,
        error: _messageFor(result),
      );
      return;
    }

    final List<NotionProperty> properties = notionPropertiesOf(result.body!);
    final NotionMapping guess = NotionMapping.match(
      databaseId: state.databaseId,
      dataSourceId: dataSourceId,
      title: state.databaseTitle,
      properties: properties,
      categoryNames: categories.map((ClassCategory c) => c.name).toList(),
    );

    // Reopening keeps every answer already given and lets the guess fill only
    // the gaps, so a column added since — to the database or to the app — is
    // offered instead of staying invisible behind an old mapping. A column
    // deleted in Notion since is dropped rather than kept: a choice pointing
    // at a property that no longer exists leaves the dropdown with a value
    // that is not among its items, which throws instead of drawing. A kept
    // choice takes the column as it is now, so an option added to Status or
    // Type since the last save is there to be answered.
    final Map<String, NotionProperty> live = <String, NotionProperty>{
      for (final NotionProperty p in properties) p.id: p,
    };
    state = state.copyWith(
      busy: false,
      stage: NotionMappingStage.fields,
      dataSourceId: dataSourceId,
      properties: properties,
      fields: <NotionField, NotionProperty>{
        ...guess.fields,
        if (keepChoices)
          for (final MapEntry<NotionField, NotionProperty> e
              in state.fields.entries)
            if (live[e.value.id] case final NotionProperty now) e.key: now,
      },
      statusMeanings: <String, LogVerdict>{
        ...guess.statusMeanings,
        if (keepChoices) ...state.statusMeanings,
      },
      kindValues: <String, String>{
        ...guess.kindValues,
        if (keepChoices) ...state.kindValues,
      },
    );
    if (onlyUnmapped) _captureGaps();
    await _findCourses();
  }

  /// The Course relation already names the table it points at, so asking
  /// the student to pick it again is a question with one right answer.
  Future<void> _findCourses() async {
    final NotionRelationTarget? target =
        state.fields[NotionField.course]?.relatesTo;
    if (state.courses != null || target == null) return;
    if (target.databaseId == state.databaseId) return;

    final NotionResult result = await _client.dataSource(target.dataSourceId);
    if (!ref.mounted || !result.ok || result.body == null) return;
    // The student may have linked one by hand while this was in flight.
    if (state.courses != null) return;

    final NotionTableChoice choice = NotionTableChoice(
      target.dataSourceId,
      notionTitleOf(result.body) ?? 'Untitled',
      target.databaseId,
    );
    final NotionCourses courses = NotionCourses.match(
      databaseId: choice.databaseId,
      dataSourceId: choice.id,
      properties: notionPropertiesOf(result.body!),
    );
    state = courses.isComplete
        ? state.copyWith(
            courses: courses,
            coursesTitle: choice.title,
            suggestedCourses: null,
          )
        : state.copyWith(suggestedCourses: choice);
  }

  /// The column the app cannot work without, and the one a table built by
  /// hand never has.
  Future<void> addKeyColumn() async {
    state = state.copyWith(busy: true, error: null);
    final NotionResult result = await _client.addProperty(
      state.dataSourceId,
      name: NotionField.key.label,
      type: 'rich_text',
    );
    if (!ref.mounted) return;
    if (!result.ok) {
      state = state.copyWith(busy: false, error: _messageFor(result));
      return;
    }
    // Re-read rather than assume: the reload's own guess is what maps the new
    // column, and it is also what proves Notion made it.
    await _loadSchema(state.dataSourceId, keepChoices: true);
  }

  Future<void> linkCourses(NotionTableChoice choice) async {
    state = state.copyWith(busy: true, error: null);
    final NotionResult result = await _client.dataSource(choice.id);
    if (!ref.mounted) return;
    if (!result.ok || result.body == null) {
      state = state.copyWith(busy: false, error: _messageFor(result));
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
      if (!ref.mounted) return;
      if (!added.ok) {
        state = state.copyWith(busy: false, error: _messageFor(added));
        return;
      }
      await _linkCoursesAgain(choice);
      return;
    }

    state = state.copyWith(
      busy: false,
      courses: courses,
      coursesTitle: choice.title,
      suggestedCourses: null,
    );
  }

  /// One retry only, after the column was added. A table still incomplete has
  /// no title column either, which is not something this screen can fix.
  Future<void> _linkCoursesAgain(NotionTableChoice choice) async {
    final NotionResult result = await _client.dataSource(choice.id);
    if (!ref.mounted) return;
    final NotionCourses courses = NotionCourses.match(
      databaseId: choice.databaseId,
      dataSourceId: choice.id,
      properties: result.body == null
          ? const <NotionProperty>[]
          : notionPropertiesOf(result.body!),
    );
    state = courses.isComplete
        ? state.copyWith(
            busy: false,
            courses: courses,
            coursesTitle: choice.title,
            suggestedCourses: null,
          )
        : state.copyWith(
            busy: false,
            error: 'That table needs a title column and a Zeolite ID column '
                'before courses can be kept in it.',
          );
  }

  void setField(NotionField field, NotionProperty? property) {
    final Map<NotionField, NotionProperty> fields =
        <NotionField, NotionProperty>{...state.fields}..remove(field);
    if (property != null) fields[field] = property;
    // The words belong to the column, so a different Status column leaves the
    // old workspace's spellings behind.
    state = state.copyWith(
      fields: fields,
      statusMeanings: field == NotionField.status
          ? NotionMapping.guessMeanings(property)
          : null,
      kindValues: field == NotionField.kind ? const <String, String>{} : null,
      suggestedCourses:
          field == NotionField.course ? null : state.suggestedCourses,
    );
    if (field == NotionField.course) unawaited(_findCourses());
  }

  void setKindValue(String word, String? option) {
    final Map<String, String> values = <String, String>{...state.kindValues}
      ..remove(word);
    if (option != null) values[word] = option;
    state = state.copyWith(kindValues: values);
  }

  void setStatusMeaning(String option, LogVerdict? meaning) {
    final Map<String, LogVerdict> meanings = <String, LogVerdict>{
      ...state.statusMeanings,
    }..remove(option);
    if (meaning != null) meanings[option] = meaning;
    state = state.copyWith(statusMeanings: meanings);
  }

  void _captureGaps() {
    final NotionMappingForm s = state;
    state = s.copyWith(
      gapFields: <NotionField>{
        for (final NotionField field in NotionField.values)
          if (!s.fields.containsKey(field)) field,
      },
      gapStatus: <String>{
        if (s.fields[NotionField.status] case final NotionProperty status)
          for (final String option in status.options)
            if (!s.statusMeanings.containsKey(option)) option,
      },
      gapKinds: <String>{
        if (s.fields.containsKey(NotionField.kind))
          for (final ClassCategory category in categories)
            if (!s.kindValues.containsKey(category.name.toLowerCase()))
              category.name.toLowerCase(),
      },
    );
  }

  Future<void> save() async {
    final NotionMappingForm s = state;
    state = s.copyWith(busy: true);
    final NotionMapping base = _loaded?.databaseId == s.databaseId
        ? _loaded!
        : NotionMapping(
            databaseId: s.databaseId,
            dataSourceId: s.dataSourceId,
            title: s.databaseTitle,
            fields: const <NotionField, NotionProperty>{},
          );

    await ref.read(notionMappingProvider.notifier).save(
          base.copyWith(
            dataSourceId: s.dataSourceId,
            title: s.databaseTitle,
            fields: s.fields,
            statusMeanings: s.statusMeanings,
            kindValues: s.kindValues,
            courses: s.courses,
          ),
        );
  }

  /// Told apart because the fixes are different: sharing a page, reconnecting,
  /// or simply waiting. One message for all three sends the user to the wrong
  /// one of the three.
  static String _messageFor(NotionResult result) {
    if (result.isNotFound) {
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
}
