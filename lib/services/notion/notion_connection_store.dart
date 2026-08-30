import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
        }),
      );

  /// Deletes the key rather than blanking it, so nothing is left behind.
  Future<void> clear() => _storage.delete(key: _key);
}
