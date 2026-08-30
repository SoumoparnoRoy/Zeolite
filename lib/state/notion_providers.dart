import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/notion/notion_auth_client.dart';
import '../services/notion/notion_connection_store.dart';

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

class NotionConnectionController extends AsyncNotifier<NotionTokens?> {
  @override
  Future<NotionTokens?> build() =>
      ref.watch(notionConnectionStoreProvider).read();

  Future<void> connect(NotionTokens tokens) async {
    await ref.read(notionConnectionStoreProvider).write(tokens);
    state = AsyncData<NotionTokens?>(tokens);
  }

  Future<void> disconnect() async {
    await ref.read(notionConnectionStoreProvider).clear();
    state = const AsyncData<NotionTokens?>(null);
  }
}
