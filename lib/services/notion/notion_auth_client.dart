import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/sync/sync_target.dart';

/// What Notion hands back once a connection is authorised. There is no
/// `expires_in` in it, so nothing here can schedule a refresh — the token is
/// used until a call answers 401.
@immutable
class NotionTokens {
  const NotionTokens({
    required this.accessToken,
    this.refreshToken,
    this.botId,
    this.workspaceId,
    this.workspaceName,
    this.workspaceIcon,
    this.duplicatedTemplateId,
  });

  /// [refreshToken] is documented as always present and read as nullable
  /// anyway: without one the connection still works, it just cannot renew.
  factory NotionTokens.fromJson(Map<String, Object?> json) => NotionTokens(
        accessToken: (json['access_token'] as String?) ?? '',
        refreshToken: json['refresh_token'] as String?,
        botId: json['bot_id'] as String?,
        workspaceId: json['workspace_id'] as String?,
        workspaceName: json['workspace_name'] as String?,
        workspaceIcon: json['workspace_icon'] as String?,
        duplicatedTemplateId: json['duplicated_template_id'] as String?,
      );

  final String accessToken;
  final String? refreshToken;
  final String? botId;

  /// Carried so Settings can name the workspace. The rest of the payload
  /// describes things this app does not do and is dropped rather than stored.
  final String? workspaceId;
  final String? workspaceName;
  final String? workspaceIcon;

  /// The database Notion copied in when the user took the template during
  /// consent, or null when they shared their own pages instead. Its presence
  /// is what says the schema on the far side is the one this app authored, so
  /// a mapping against it is known rather than guessed.
  final String? duplicatedTemplateId;

  bool get isUsable => accessToken.isNotEmpty;
}

/// A token call that either produced tokens or a reason it did not. Shaped
/// like [SyncOutcome] rather than throwing: the caller has to tell "retry" from
/// "this connection is finished", which the sync layer's enum already says.
@immutable
class NotionAuthResult {
  const NotionAuthResult.done(NotionTokens this.tokens)
      : failure = null,
        message = null;

  const NotionAuthResult.failed(this.failure, {this.message}) : tokens = null;

  final NotionTokens? tokens;
  final SyncFailure? failure;
  final String? message;

  bool get ok => failure == null;
}

/// The device's half of the OAuth handshake with `server/`, which exists only
/// because the client secret both token calls need must not sit in an APK.
/// Attendance never comes through here — once connected the app calls Notion
/// directly, so this is reached twice in a user's life.
class NotionAuthClient {
  NotionAuthClient({http.Client? httpClient, Uri? baseUri})
      : _http = httpClient ?? http.Client(),
        _base = baseUri ?? Uri.parse(defaultBaseUrl);

  static const String defaultBaseUrl = 'https://zeolite.onrender.com';

  /// A free host spins the service down when it is idle, and waking it takes
  /// far longer than any request it then serves. Both calls that can be the
  /// one doing the waking wear this instead of a normal timeout, or the first
  /// attempt after a quiet spell is guaranteed to fail.
  static const Duration _wakeTimeout = Duration(seconds: 90);

  /// A claim always follows the browser round trip, by which point the service
  /// has just served `/start` and `/callback` and is certainly awake.
  static const Duration _callTimeout = Duration(seconds: 30);

  final http.Client _http;
  final Uri _base;

  /// Called when the connect screen opens, so the host is awake before anyone
  /// taps Connect. Advisory: false means the wake-up did not land in time, not
  /// that connecting will fail.
  Future<bool> health() async {
    try {
      final http.Response response = await _http
          .get(_base.resolve('/health'))
          .timeout(_wakeTimeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Where to send the browser. The verifier is not in it — only its hash,
  /// which is the point of the whole exchange.
  Uri startUri(String challenge) => _base.resolve('/notion/start').replace(
        queryParameters: <String, String>{'challenge': challenge},
      );

  /// Trades the verifier for the tokens.
  ///
  /// [session] arrives on the `zeolite://` redirect. [pairingCode] is the
  /// fallback the callback page prints for the user to type, for the browsers
  /// that drop a custom-scheme return — it is normalised here because a code
  /// read off a screen arrives with the spaces and case the reader felt like,
  /// and the server matches it exactly.
  ///
  /// Exactly one of the two is used; [session] wins if both are given.
  Future<NotionAuthResult> claim({
    String? session,
    String? pairingCode,
    required String verifier,
  }) {
    final String? code =
        pairingCode?.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if ((session == null || session.isEmpty) && (code == null || code.isEmpty)) {
      return Future<NotionAuthResult>.value(
        const NotionAuthResult.failed(SyncFailure.rejected),
      );
    }
    return _post(
      '/notion/claim',
      <String, String>{
        if (session != null && session.isNotEmpty)
          'session': session
        else
          'code': code!,
        'verifier': verifier,
      },
      _callTimeout,
    );
  }

  /// Reactive only — call this when Notion answers 401, never on a timer.
  Future<NotionAuthResult> refresh(String refreshToken) => _post(
        '/notion/refresh',
        <String, String>{'refresh_token': refreshToken},
        _wakeTimeout,
      );

  Future<NotionAuthResult> _post(
    String path,
    Map<String, String> body,
    Duration timeout,
  ) async {
    try {
      final http.Response response = await _http
          .post(
            _base.resolve(path),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
      return _read(response);
    } on TimeoutException {
      return const NotionAuthResult.failed(SyncFailure.offline);
    } on http.ClientException {
      return const NotionAuthResult.failed(SyncFailure.offline);
    } catch (_) {
      return const NotionAuthResult.failed(SyncFailure.unknown);
    }
  }

  NotionAuthResult _read(http.Response response) {
    if (response.statusCode == 200) {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        return const NotionAuthResult.failed(SyncFailure.unknown);
      }
      final NotionTokens tokens = NotionTokens.fromJson(decoded);
      return tokens.isUsable
          ? NotionAuthResult.done(tokens)
          : const NotionAuthResult.failed(SyncFailure.unknown);
    }

    switch (response.statusCode) {
      // The service refuses every bad claim identically so a caller cannot
      // learn which part was wrong. Either way, connect again.
      case 400:
        return const NotionAuthResult.failed(SyncFailure.rejected);
      case 401:
      case 403:
        return const NotionAuthResult.failed(SyncFailure.auth);
      case 429:
        return const NotionAuthResult.failed(SyncFailure.rateLimited);
      // Notion's failure, not ours — worth retrying on backoff.
      case 502:
        return const NotionAuthResult.failed(SyncFailure.unknown);
      default:
        return const NotionAuthResult.failed(SyncFailure.unknown);
    }
  }
}
