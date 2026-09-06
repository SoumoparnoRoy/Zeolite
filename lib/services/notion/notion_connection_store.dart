import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/notion/notion_mapping.dart';
import 'notion_auth_client.dart';

/// Where a Notion connection lives between launches. Keystore-backed rather
/// than `shared_preferences`, which is plain XML on disk: the access token
/// grants write access to a whole workspace, so it is the one value here worth
/// encrypting at rest.
///
/// Nothing to do with the signed-in account — connecting never needed one and
/// the token is never uploaded, so a sign-out leaves it alone.
class NotionConnectionStore {
  NotionConnectionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _key = 'notion_connection';
  static const String _retiredKey = 'notion_retired_database';

  final FlutterSecureStorage _storage;

  /// Null both when nothing is connected and when what is stored no longer
  /// parses. Reconnecting is the recovery either way.
  Future<NotionTokens?> read() async {
    final String? raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final NotionTokens tokens = NotionTokens.fromJson(decoded);
    return tokens.isUsable ? tokens : null;
  }

  /// Stored in the shape Notion sent, so a field added to the token response
  /// survives a round trip through here without a migration.
  Future<void> write(NotionTokens tokens) => _storage.write(
        key: _key,
        value: jsonEncode(<String, Object?>{
          'access_token': tokens.accessToken,
          'refresh_token': tokens.refreshToken,
          'bot_id': tokens.botId,
          'workspace_id': tokens.workspaceId,
          'workspace_name': tokens.workspaceName,
          'workspace_icon': tokens.workspaceIcon,
          'duplicated_template_id': tokens.duplicatedTemplateId,
        }),
      );

  /// Deletes the keys rather than blanking them, so nothing is left behind.
  ///
  /// The mapping goes with the token deliberately: it names a data source in
  /// one workspace, so outliving the connection could only ever leave it
  /// pointing somewhere the user no longer is.
  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _storage.delete(key: _mappingKey);
    await clearRetired();
  }

  /// The databases a template migration moved off, kept only so the offer to
  /// retire them survives the moment it was made.
  ///
  /// Taking a new template asks once what should happen to the old database,
  /// and "leave it for now" is a reasonable answer that used to be final —
  /// there was no way back to that choice afterwards.
  ///
  /// A list rather than one slot: retaking twice without answering the first
  /// prompt used to overwrite the first record, stranding that page in Notion
  /// with nothing in the app able to reach it.
  Future<void> writeRetired(
    String databaseId,
    String title, {
    String? pageId,
    DateTime? retiredAt,
  }) async {
    final List<RetiredNotionDatabase> kept = await readRetired();
    // Keyed by database id so the rename path, which records the same one
    // again under the name the rename settled on, replaces instead of doubles.
    final int at =
        kept.indexWhere((RetiredNotionDatabase e) => e.id == databaseId);
    final RetiredNotionDatabase entry = RetiredNotionDatabase(
      id: databaseId,
      title: title,
      pageId: pageId,
      // Every retake produces a database with the same template name, so the
      // moment it was left behind is the only thing telling two of them apart.
      retiredAt: retiredAt ?? (at == -1 ? DateTime.now() : kept[at].retiredAt),
    );
    if (at == -1) {
      kept.add(entry);
    } else {
      kept[at] = entry;
    }
    await _writeRetired(kept);
  }

  /// Oldest first, which is the order they were left behind in.
  ///
  /// Reads the single object earlier versions stored as well as the list, so
  /// an install upgrading with an offer still open does not lose it.
  Future<List<RetiredNotionDatabase>> readRetired() async {
    final String? raw = await _storage.read(key: _retiredKey);
    if (raw == null || raw.isEmpty) return <RetiredNotionDatabase>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return <RetiredNotionDatabase>[];
    }
    final List<Object?> entries = switch (decoded) {
      final List<Object?> many => many,
      final Map<String, Object?> one => <Object?>[one],
      _ => const <Object?>[],
    };
    return <RetiredNotionDatabase>[
      for (final Object? entry in entries)
        if (_retiredFrom(entry) case final RetiredNotionDatabase read) read,
    ];
  }

  /// Only the one dealt with: clearing them all here is how a pending offer
  /// for a different page would go missing.
  Future<void> removeRetired(String databaseId) async {
    final List<RetiredNotionDatabase> kept = await readRetired();
    kept.removeWhere((RetiredNotionDatabase e) => e.id == databaseId);
    if (kept.isEmpty) return clearRetired();
    await _writeRetired(kept);
  }

  Future<void> clearRetired() => _storage.delete(key: _retiredKey);

  Future<void> _writeRetired(List<RetiredNotionDatabase> entries) =>
      _storage.write(
        key: _retiredKey,
        value: jsonEncode(<Map<String, Object?>>[
          for (final RetiredNotionDatabase e in entries)
            <String, Object?>{
              'id': e.id,
              'title': e.title,
              if (e.pageId != null) 'pageId': e.pageId,
              if (e.retiredAt != null)
                'retiredAt': e.retiredAt!.toIso8601String(),
            },
        ]),
      );

  static RetiredNotionDatabase? _retiredFrom(Object? entry) {
    if (entry is! Map<String, Object?>) return null;
    final String? id = entry['id'] as String?;
    if (id == null || id.isEmpty) return null;
    return RetiredNotionDatabase(
      id: id,
      title: (entry['title'] as String?) ?? 'the old database',
      pageId: entry['pageId'] as String?,
      // Null on a record written before this was stored, and on one whose
      // stamp no longer parses. The row simply goes without a date.
      retiredAt: DateTime.tryParse((entry['retiredAt'] as String?) ?? ''),
    );
  }

  /// Which data source attendance is filed in, and which column holds what.
  /// Null until the user has been through the mapping screen.
  Future<NotionMapping?> readMapping() async {
    final String? raw = await _storage.read(key: _mappingKey);
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    return NotionMapping.fromJson(decoded);
  }

  Future<void> writeMapping(NotionMapping mapping) =>
      _storage.write(key: _mappingKey, value: jsonEncode(mapping.toJson()));

  /// Keeps the verifier of an attempt that is still in the browser.
  ///
  /// It has to outlive the screen: leaving it, or Android evicting the app
  /// while the browser is in front, would otherwise end the attempt silently
  /// and invalidate a pairing code the user is already holding.
  Future<void> writePending(String verifier, {DateTime? startedAt}) =>
      _storage.write(
        key: _pendingKey,
        value: jsonEncode(<String, Object?>{
          'verifier': verifier,
          'startedAt':
              (startedAt ?? DateTime.now()).millisecondsSinceEpoch,
        }),
      );

  /// Null once the attempt is older than the service will keep its session
  /// for, since the verifier is then unusable and is only a secret at rest.
  Future<String?> readPending({DateTime? now}) async {
    final String? raw = await _storage.read(key: _pendingKey);
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;

    final String? verifier = decoded['verifier'] as String?;
    final int? startedAt = decoded['startedAt'] as int?;
    if (verifier == null || verifier.isEmpty || startedAt == null) return null;

    final DateTime began = DateTime.fromMillisecondsSinceEpoch(startedAt);
    if ((now ?? DateTime.now()).difference(began) >= pendingLifetime) {
      return null;
    }
    return verifier;
  }

  Future<void> clearPending() => _storage.delete(key: _pendingKey);

  /// Mirrors `SESSION_TTL_MS` in `server/src/sessions.js`. Past it the service
  /// has dropped the session, so holding the verifier buys nothing.
  static const Duration pendingLifetime = Duration(minutes: 5);

  static const String _pendingKey = 'notion_pending';

  static const String _mappingKey = 'notion_mapping';
}

/// A database a migration left behind, still full of the user's rows.
@immutable
class RetiredNotionDatabase {
  const RetiredNotionDatabase({
    required this.id,
    required this.title,
    this.pageId,
    this.retiredAt,
  });

  final String id;
  final String title;

  /// When the migration left it behind. Null on a record from a version that
  /// did not store one.
  final DateTime? retiredAt;

  /// The template page [id] sits in, when it came from one. Retiring the
  /// database alone would leave that page and its Courses table behind.
  final String? pageId;
}
