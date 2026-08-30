import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/sync/sync_target.dart';

/// One Notion call that either decoded or gave a reason it did not. Shaped
/// like [NotionAuthResult] next door rather than throwing, so the whole
/// service folder answers a failed call the same way.
@immutable
class NotionResult {
  const NotionResult.done(Map<String, Object?> this.body)
      : failure = null,
        message = null;

  const NotionResult.failed(this.failure, {this.message}) : body = null;

  final Map<String, Object?>? body;
  final SyncFailure? failure;

  /// Notion's own error code — `object_not_found`, `validation_error`. Carried
  /// because the caller acts on it: a page that is already gone is a finished
  /// archive, not a failure to retry.
  final String? message;

  bool get ok => failure == null;
}

/// Every row of a data source, or the reason the walk stopped.
///
/// Separate from [NotionResult] because a partial answer is not a shorter
/// answer: a table read half way and reported whole reads as rows somebody
/// deleted.
@immutable
class NotionRows {
  const NotionRows.done(this.pages)
      : failure = null,
        message = null;

  const NotionRows.failed(this.failure, {this.message})
      : pages = const <Map<String, Object?>>[];

  final List<Map<String, Object?>> pages;
  final SyncFailure? failure;
  final String? message;

  bool get ok => failure == null;
}

/// The device's calls to Notion.
///
/// Speaks pages and data sources only — nothing here knows what a mark is, and
/// turning a `SyncItem` into properties belongs to `NotionSyncTarget`.
///
/// Since 2025-09-03 a database is a container for one or more *data sources*
/// and the schema lives on the data source, so a page parents on a
/// `data_source_id` and the property list is read from `/v1/data_sources`.
class NotionClient {
  NotionClient({
    required Future<String?> Function() accessToken,
    required Future<bool> Function() refresh,
    http.Client? httpClient,
    Uri? baseUri,
    this.minimumGap = const Duration(milliseconds: 350),
  })  : _accessToken = accessToken,
        _refresh = refresh,
        _http = httpClient ?? http.Client(),
        _base = baseUri ?? Uri.parse(defaultBaseUrl);

  static const String defaultBaseUrl = 'https://api.notion.com';

  /// Pinned, not tracked: Notion keeps a version working, and a call shaped
  /// for one data model against another fails in ways that read as app bugs.
  static const String apiVersion = '2026-03-11';

  /// Both callbacks are required so a caller cannot half-wire the connection.
  /// Refreshing is the token owner's job, not this class's, so exactly one
  /// refresh runs however many calls meet a 401 at once — two would race, and
  /// the loser would spend a refresh token that has already been rotated.
  final Future<String?> Function() _accessToken;
  final Future<bool> Function() _refresh;

  final http.Client _http;
  final Uri _base;

  /// Notion allows roughly three requests a second. A first push is a term of
  /// marks, so requests are spaced here instead of tripping the limit and
  /// unwinding through backoff.
  final Duration minimumGap;

  Future<void> _gate = Future<void>.value();
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _timeout = Duration(seconds: 30);

  /// How many rows one query asks for before the cursor is followed again.
  static const int queryPageSize = 100;

  static const int maxPages = 20;

  /// The tables the connection can see. `database` is not a value search
  /// takes any more, and asking for one is a validation error rather than an
  /// empty list. Paged, and this never loops — the caller hands the cursor
  /// back.
  Future<NotionResult> searchDataSources({String? cursor}) => _send(
        'POST',
        '/v1/search',
        body: <String, Object?>{
          'filter': <String, String>{
            'value': 'data_source',
            'property': 'object',
          },
          if (cursor != null) 'start_cursor': cursor,
        },
      );

  /// Returns the container, whose `data_sources` list is the thing worth
  /// having — a database holding two of them is why the mapping screen has to
  /// ask which, rather than assume.
  Future<NotionResult> database(String databaseId) =>
      _send('GET', '/v1/databases/$databaseId');

  /// Where the property schema lives, and so what auto-matching runs against.
  Future<NotionResult> dataSource(String dataSourceId) =>
      _send('GET', '/v1/data_sources/$dataSourceId');

  Future<NotionResult> queryDataSource(
    String dataSourceId, {
    String? cursor,
    Map<String, Object?>? filter,
    int? pageSize,
  }) =>
      _send(
        'POST',
        '/v1/data_sources/$dataSourceId/query',
        body: <String, Object?>{
          if (filter != null) 'filter': filter,
          if (cursor != null) 'start_cursor': cursor,
          if (pageSize != null) 'page_size': pageSize,
        },
      );

  /// One page, for the far side of a relation — a relation cell holds ids and
  /// no names, so the course it points at has to be read to be named.
  Future<NotionResult> page(String pageId) =>
      _send('GET', '/v1/pages/$pageId');

  /// Walks the cursor to the end of a data source.
  ///
  /// [maxPages] stops a run pulling a whole workspace into memory on a
  /// database somebody else fills too, and a walk that ends there is still
  /// reported as done: the alternative is refusing to read a large table at
  /// all.
  Future<NotionRows> queryAllPages(String dataSourceId) async {
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    String? cursor;
    for (int walked = 0; walked < maxPages; walked++) {
      final NotionResult result = await queryDataSource(
        dataSourceId,
        cursor: cursor,
        pageSize: queryPageSize,
      );
      if (!result.ok) {
        return NotionRows.failed(result.failure, message: result.message);
      }

      final Object? rows = result.body?['results'];
      if (rows is List<Object?>) {
        for (final Object? row in rows) {
          if (row is Map<String, Object?>) pages.add(row);
        }
      }

      if (result.body?['has_more'] != true) break;
      cursor = result.body?['next_cursor'] as String?;
      if (cursor == null) break;
    }
    return NotionRows.done(pages);
  }

  Future<NotionResult> createPage({
    required String dataSourceId,
    required Map<String, Object?> properties,
  }) =>
      _send(
        'POST',
        '/v1/pages',
        body: <String, Object?>{
          'parent': <String, String>{
            'type': 'data_source_id',
            'data_source_id': dataSourceId,
          },
          'properties': properties,
        },
      );

  Future<NotionResult> updatePage(
    String pageId,
    Map<String, Object?> properties,
  ) =>
      _send(
        'PATCH',
        '/v1/pages/$pageId',
        body: <String, Object?>{'properties': properties},
      );

  /// Trash, not `is_archived` — they are two separate states now. A trashed
  /// page is recoverable by the user, which is the whole reason the sync plan
  /// is willing to remove one without asking first.
  Future<NotionResult> trashPage(String pageId) => _send(
        'PATCH',
        '/v1/pages/$pageId',
        body: <String, Object?>{'in_trash': true},
      );

  /// One retry, never a ladder: `SyncCoordinator` already backs off to half an
  /// hour, and a second ladder nested inside it turns a dead host into a run
  /// that looks hung.
  Future<NotionResult> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final NotionResult first = await _attempt(method, path, body);
    if (first.failure != SyncFailure.auth || first.message != _expired) {
      return first;
    }
    if (!await _refresh()) {
      return const NotionResult.failed(SyncFailure.auth);
    }
    return _attempt(method, path, body);
  }

  Future<NotionResult> _attempt(
    String method,
    String path,
    Map<String, Object?>? body,
  ) async {
    final String? token = await _accessToken();
    if (token == null || token.isEmpty) {
      return const NotionResult.failed(SyncFailure.auth);
    }

    await _pace();

    try {
      final http.Request request = http.Request(method, _base.resolve(path))
        ..headers.addAll(<String, String>{
          'Authorization': 'Bearer $token',
          'Notion-Version': apiVersion,
          if (body != null) 'Content-Type': 'application/json',
        });
      if (body != null) request.body = jsonEncode(body);

      final http.Response response = await http.Response.fromStream(
        await _http.send(request).timeout(_timeout),
      );
      return _read(response);
    } on TimeoutException {
      return const NotionResult.failed(SyncFailure.offline);
    } on http.ClientException {
      return const NotionResult.failed(SyncFailure.offline);
    } catch (error) {
      return NotionResult.failed(SyncFailure.unknown, message: '$error');
    }
  }

  /// Spaces the *start* of each request rather than serialising whole calls:
  /// the limit is on how often Notion is asked, and waiting for each response
  /// before sending the next would make a large push slower than it needs to
  /// be.
  Future<void> _pace() {
    final Future<void> turn = _gate.then((_) async {
      final Duration since = DateTime.now().difference(_lastSentAt);
      if (since < minimumGap) {
        await Future<void>.delayed(minimumGap - since);
      }
      _lastSentAt = DateTime.now();
    });
    _gate = turn;
    return turn;
  }

  NotionResult _read(http.Response response) {
    final Map<String, Object?>? decoded = _decode(response.body);

    if (response.statusCode == 200) {
      return decoded == null
          ? const NotionResult.failed(SyncFailure.unknown)
          : NotionResult.done(decoded);
    }

    final String? code = decoded?['code'] as String?;
    switch (response.statusCode) {
      case 401:
        return NotionResult.failed(SyncFailure.auth, message: code ?? _expired);
      // Not something a new token fixes — either the connection was never
      // given the capability, or the page is not shared with it.
      case 403:
        return NotionResult.failed(SyncFailure.auth, message: code);
      case 400:
      case 404:
        return NotionResult.failed(SyncFailure.rejected, message: code);
      case 429:
        return NotionResult.failed(SyncFailure.rateLimited, message: code);
      // Notion's word for two writers colliding, which is worth another run.
      case 409:
        return NotionResult.failed(SyncFailure.unknown, message: code);
      default:
        return NotionResult.failed(SyncFailure.unknown, message: code);
    }
  }

  static Map<String, Object?>? _decode(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// What Notion calls an expired or invalid token, and the only 401 where
  /// refreshing is the answer.
  static const String _expired = 'unauthorized';
}
