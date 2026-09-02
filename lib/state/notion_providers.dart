import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/notion/notion_mapping.dart';
import '../domain/sync/sync_target.dart';
import '../services/notion/notion_auth_client.dart';
import '../services/notion/notion_client.dart';
import '../services/notion/notion_connection_store.dart';
import 'providers.dart';

final notionAuthClientProvider =
    Provider<NotionAuthClient>((ref) => NotionAuthClient());

final notionConnectionStoreProvider =
    Provider<NotionConnectionStore>((ref) => NotionConnectionStore());

/// The connected workspace, or null. Deliberately not derived from the signed
/// in user: connecting Notion never needed an account, so this survives a
/// sign-out and is cleared only by disconnecting.
final notionConnectionProvider =
    AsyncNotifierProvider<NotionConnectionController, NotionTokens?>(
  NotionConnectionController.new,
);

/// Calls to Notion, holding no token of its own.
///
/// The controller supplies both callbacks because it owns the connection:
/// that is what makes one refresh run however many calls meet a 401 together,
/// and what lets a connection that has genuinely ended reach the screen
/// instead of only the caller.
/// The database a template migration left behind, until the user retires it.
final retiredNotionDatabaseProvider =
    FutureProvider<RetiredNotionDatabase?>((ref) async {
  if (ref.watch(notionConnectionProvider).value == null) return null;
  return ref.read(notionConnectionStoreProvider).readRetired();
});

final notionClientProvider = Provider<NotionClient>((ref) {
  final NotionConnectionController connection =
      ref.watch(notionConnectionProvider.notifier);
  return NotionClient(
    accessToken: connection.accessToken,
    refresh: connection.refresh,
  );
});

/// Which data source attendance is filed in. Null until the user has answered
/// the mapping screen, and gone as soon as the connection is.
final notionMappingProvider =
    AsyncNotifierProvider<NotionMappingController, NotionMapping?>(
  NotionMappingController.new,
);

class NotionConnectionController extends AsyncNotifier<NotionTokens?> {
  Future<bool>? _refreshing;

  @override
  Future<NotionTokens?> build() =>
      ref.watch(notionConnectionStoreProvider).read();

  Future<void> connect(NotionTokens tokens) async {
    await ref.read(notionConnectionStoreProvider).write(tokens);
    unawaited(ref.read(analyticsProvider).notionConnected());
    state = AsyncData<NotionTokens?>(tokens);
  }

  Future<void> disconnect() async {
    await ref.read(notionConnectionStoreProvider).clear();
    state = const AsyncData<NotionTokens?>(null);
  }

  /// Read through the store rather than off [state], so a token renewed by
  /// another part of the app is never missed.
  Future<String?> accessToken() async {
    final NotionTokens? tokens =
        state.value ?? await ref.read(notionConnectionStoreProvider).read();
    return tokens?.accessToken;
  }

  /// One refresh at a time. Notion rotates the refresh token, so a second
  /// attempt started with the spent one is rejected and the connection is
  /// finished — which is why this lives with the connection and not in the
  /// client that meets the 401.
  Future<bool> refresh() {
    final Future<bool>? running = _refreshing;
    if (running != null) return running;
    final Future<bool> attempt = _renew();
    _refreshing = attempt;
    return attempt.whenComplete(() => _refreshing = null);
  }

  Future<bool> _renew() async {
    final NotionConnectionStore store =
        ref.read(notionConnectionStoreProvider);
    final NotionTokens? current = state.value ?? await store.read();
    final String? token = current?.refreshToken;
    if (current == null || token == null || token.isEmpty) {
      await disconnect();
      return false;
    }

    final NotionAuthResult result =
        await ref.read(notionAuthClientProvider).refresh(token);
    if (!result.ok || result.tokens == null) {
      // Being offline is not a connection that has ended, and disconnecting on
      // one would make a tunnel look like a revoked authorisation.
      if (result.failure == SyncFailure.auth ||
          result.failure == SyncFailure.rejected) {
        await disconnect();
      }
      return false;
    }

    // A refresh answers with the token and little else, so what describes the
    // workspace is carried over rather than blanked — Settings names it from
    // here, and the template id is what says the schema is ours.
    final NotionTokens renewed = result.tokens!;
    await connect(
      NotionTokens(
        accessToken: renewed.accessToken,
        refreshToken: renewed.refreshToken ?? current.refreshToken,
        botId: renewed.botId ?? current.botId,
        workspaceId: renewed.workspaceId ?? current.workspaceId,
        workspaceName: renewed.workspaceName ?? current.workspaceName,
        workspaceIcon: renewed.workspaceIcon ?? current.workspaceIcon,
        duplicatedTemplateId:
            renewed.duplicatedTemplateId ?? current.duplicatedTemplateId,
      ),
    );
    return true;
  }
}

class NotionMappingController extends AsyncNotifier<NotionMapping?> {
  @override
  Future<NotionMapping?> build() async {
    // Rebuilt with the connection, so disconnecting takes the mapping with it
    // rather than leaving one that names a workspace nobody is in.
    final NotionTokens? tokens =
        await ref.watch(notionConnectionProvider.future);
    if (tokens == null) return null;
    return ref.watch(notionConnectionStoreProvider).readMapping();
  }

  Future<void> save(NotionMapping mapping) async {
    await ref.read(notionConnectionStoreProvider).writeMapping(mapping);
    state = AsyncData<NotionMapping?>(mapping);
  }

  /// Nothing matches a database by its name — the mapping is columns — so a
  /// rename in Notion reaches nothing, and Settings goes on naming a table
  /// under a name it no longer has. A read that fails keeps what is stored.
  Future<void> refreshTitle() async {
    final NotionMapping? mapping = state.value;
    if (mapping == null || mapping.databaseId.isEmpty) return;

    final NotionResult result =
        await ref.read(notionClientProvider).database(mapping.databaseId);
    if (!result.ok) return;

    final String? title = notionTitleOf(result.body);
    if (title == null || title == mapping.title) return;
    await save(mapping.copyWith(title: title));
  }

  /// Maps the database Notion copied in during consent, without asking.
  ///
  /// Only ever called with `duplicated_template_id`, so the schema on the far
  /// side is the one this app authored and there is nothing to guess. False
  /// means something did not line up after all, and the caller shows the
  /// screen — a silent half-mapping would be worse than a question.
  Future<bool> adoptTemplate(String databaseId) async {
    for (int attempt = 0; attempt < _adoptAttempts; attempt++) {
      if (await _adopt(databaseId)) return true;
      if (attempt == _adoptAttempts - 1) break;
      await Future<void>.delayed(_adoptBackoff * (1 << attempt));
    }
    return false;
  }

  /// Straight after consent Notion answers the database but with
  /// `data_sources: []` — the copy is not finished. Retried rather than slept
  /// on: a delay long enough to always be safe feels broken.
  static const int _adoptAttempts = 5;
  static const Duration _adoptBackoff = Duration(milliseconds: 400);

  /// A template that has to deliver two related databases is a *page* holding
  /// both: a relation only survives duplication when both ends are copied in
  /// the same operation, so the id consent hands back is the page's, not a
  /// database's. Its children are tried in turn, and the one that maps
  /// completely wins — a Courses table has no Date or Status column, so it
  /// cannot be mistaken for the attendance one.
  Future<bool> _adopt(String id) async {
    if (await _adoptDatabase(id)) return true;

    final List<String> children = await _childDatabasesOf(id);
    for (final String child in children) {
      if (!await _adoptDatabase(child)) continue;
      // The Courses table is whichever sibling is not the one marks are filed
      // in. Looked up only after the attendance table is settled, so a
      // template without one still adopts exactly as it did before.
      await _adoptCourses(children.where((String c) => c != child));
      return true;
    }
    return false;
  }

  Future<void> _adoptCourses(Iterable<String> candidates) async {
    final NotionClient client = ref.read(notionClientProvider);
    for (final String databaseId in candidates) {
      final NotionResult database = await client.database(databaseId);
      final String? dataSourceId = _firstDataSourceOf(database.body);
      if (dataSourceId == null) continue;

      final NotionResult source = await client.dataSource(dataSourceId);
      final Map<String, Object?>? body = source.body;
      if (body == null) continue;

      final NotionCourses courses = NotionCourses.match(
        databaseId: databaseId,
        dataSourceId: dataSourceId,
        properties: notionPropertiesOf(body),
      );
      if (!courses.isComplete) continue;

      final NotionMapping? mapping = state.value;
      if (mapping == null) return;
      await save(mapping.copyWith(courses: courses));
      return;
    }
  }

  /// Walks down, not just across: a database tucked inside a toggle heading is
  /// a child of that heading rather than of the page, and laying the template
  /// out with headings is the natural thing to do.
  static const int _blockScanLimit = 8;

  Future<List<String>> _childDatabasesOf(String pageId) async {
    final NotionClient client = ref.read(notionClientProvider);
    final List<String> found = <String>[];
    final List<String> toVisit = <String>[pageId];

    for (int calls = 0; toVisit.isNotEmpty && calls < _blockScanLimit; calls++) {
      final NotionResult result =
          await client.blockChildren(toVisit.removeAt(0));
      final Object? blocks = result.body?['results'];
      if (blocks is! List<Object?>) continue;

      for (final Object? block in blocks) {
        if (block is! Map<String, Object?>) continue;
        final String? id = block['id'] as String?;
        if (id == null) continue;
        if (block['type'] == 'child_database') {
          found.add(id);
        } else if (block['has_children'] == true) {
          toVisit.add(id);
        }
      }
    }
    return found;
  }

  Future<bool> _adoptDatabase(String databaseId) async {
    final NotionClient client = ref.read(notionClientProvider);

    final NotionResult database = await client.database(databaseId);
    final String? dataSourceId = _firstDataSourceOf(database.body);
    if (dataSourceId == null) return false;

    final NotionResult source = await client.dataSource(dataSourceId);
    final Map<String, Object?>? body = source.body;
    if (body == null) return false;

    final NotionMapping mapping = NotionMapping.match(
      databaseId: databaseId,
      dataSourceId: dataSourceId,
      title: notionTitleOf(database.body) ?? 'Notion',
      properties: notionPropertiesOf(body),
    );
    if (!mapping.isComplete) return false;

    await save(mapping);
    return true;
  }

  static String? _firstDataSourceOf(Map<String, Object?>? body) {
    final Object? sources = body?['data_sources'];
    if (sources is! List<Object?> || sources.isEmpty) return null;
    final Object? first = sources.first;
    return first is Map<String, Object?> ? first['id'] as String? : null;
  }
}

/// Notion writes a database's name as rich text and a data source's as a
/// plain string, so both shapes are read here rather than at each call site.
String? notionTitleOf(Map<String, Object?>? body) {
  if (body == null) return null;
  final Object? name = body['name'];
  if (name is String && name.isNotEmpty) return name;

  final Object? title = body['title'];
  if (title is! List<Object?>) return null;
  final String joined = title
      .whereType<Map<String, Object?>>()
      .map((Map<String, Object?> part) => part['plain_text'])
      .whereType<String>()
      .join();
  return joined.isEmpty ? null : joined;
}

List<NotionProperty> notionPropertiesOf(Map<String, Object?> dataSource) {
  final Object? properties = dataSource['properties'];
  if (properties is! Map<String, Object?>) return const <NotionProperty>[];
  return <NotionProperty>[
    for (final MapEntry<String, Object?> entry in properties.entries)
      if (entry.value is Map<String, Object?>)
        NotionProperty.fromJson(entry.key, entry.value! as Map<String, Object?>),
  ];
}
