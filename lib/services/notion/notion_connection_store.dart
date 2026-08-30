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
}
