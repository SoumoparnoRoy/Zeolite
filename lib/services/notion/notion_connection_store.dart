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

  /// The database a template migration moved off, kept only so the offer to
  /// retire it survives the moment it was made.
  ///
  /// Taking a new template asks once what should happen to the old database,
  /// and "leave it for now" is a reasonable answer that used to be final —
  /// there was no way back to that choice afterwards.
  Future<void> writeRetired(String databaseId, String title) => _storage.write(
        key: _retiredKey,
        value: jsonEncode(<String, Object?>{'id': databaseId, 'title': title}),
      );

  Future<RetiredNotionDatabase?> readRetired() async {
    final String? raw = await _storage.read(key: _retiredKey);
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final String? id = decoded['id'] as String?;
    if (id == null || id.isEmpty) return null;
    return RetiredNotionDatabase(
      id: id,
      title: (decoded['title'] as String?) ?? 'the old database',
    );
  }

  Future<void> clearRetired() => _storage.delete(key: _retiredKey);

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
  const RetiredNotionDatabase({required this.id, required this.title});

  final String id;
  final String title;
}
