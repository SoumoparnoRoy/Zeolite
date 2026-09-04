import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../domain/sync/sync_merge.dart';
import '../../domain/sync/sync_status.dart';
import '../../services/auth_service.dart';
import '../../services/sync/sync_coordinator.dart';
import '../../state/auth_providers.dart';
import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import 'auth_form.dart';
import 'sync_status_line.dart';
import 'sync_merge_screen.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// Signing in is optional and buys backup and sync across devices. Notion is
/// deliberately not on that list — it holds its own token on the device and
/// never touches the account, so gating it here would be friction with nothing
/// behind it. Everything else works signed out and always has, so this screen
/// never stands between anyone and their attendance.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<User?> user = ref.watch(signedInUserProvider);

    return PushScaffold(
      title: 'Account',
      subtitle: user.value?.email,
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          sliver: SliverList.list(
            children: <Widget>[
              user.when(
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (Object error, StackTrace _) => _Hint(
                  'Could not reach the account service. Everything on this '
                  'device still works.',
                ),
                data: (User? signedIn) => signedIn == null
                    ? const AuthForm()
                    : _SignedIn(user: signedIn),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SignedIn extends ConsumerWidget {
  const _SignedIn({required this.user});

  final User user;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete this account?'),
            content: const Text(
              'Your account and everything backed up to it are deleted for '
              'good. Attendance already on this device stays where it is.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AuthResult result =
        await ref.read(authServiceProvider).deleteAccount();
    if (!result.ok) {
      messenger.showSnackBar(SnackBar(content: Text(authFailureMessage(result.failure!))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Signed in', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(
                user.email ?? 'this device',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton(
          onPressed: () => ref.read(authServiceProvider).signOut(),
          child: const Text('Sign out'),
        ),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('Sync'),
        const _SyncSection(),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader('Deleting your account'),
        const _Hint(
          'Deletion removes the account and everything backed up to it. '
          'You can also do this from the web without reinstalling — the '
          'address is in the privacy policy.',
        ),
        const SizedBox(height: AppSpacing.sm),
        TextButton(
          onPressed: () => _delete(context, ref),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('Delete my account'),
        ),
      ],
    );
  }
}

/// The one place a run can be started by hand, and the only place a failed one
/// is ever mentioned.
class _SyncSection extends ConsumerWidget {
  const _SyncSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SyncStatus status = ref.watch(syncStatusProvider);
    final SyncRunResult? last = ref.read(syncStatusProvider.notifier).lastResult;
    final bool running = status.state == SyncState.running;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SurfaceCard(
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: 20,
                child: running
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Icon(
                        _iconFor(status, last),
                        size: 20,
                        color: status.state == SyncState.idle
                            ? context.palette.textTertiary
                            : Theme.of(context).colorScheme.error,
                      ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  syncStatusLine(
                    status,
                    last,
                    storedLastSyncAt:
                        ref.watch(settingsProvider).value?.lastSyncAt,
                  ),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (last?.outcome == SyncRunOutcome.reviewNeeded)
          FilledButton(
            onPressed: running ? null : () => _review(context, ref),
            child: const Text('Review and merge'),
          )
        else
          OutlinedButton(
            onPressed: running
                ? null
                // Forced: a Retry that honours the backoff is not a Retry.
                : () => ref.read(syncStatusProvider.notifier).run(force: true),
            child: Text(status.failures > 0 ? 'Try again' : 'Sync now'),
          ),
      ],
    );
  }

  /// Read fresh rather than reusing what the run returned: the user may have
  /// marked something since, and a merge screen built on a stale reading would
  /// offer decisions about rows that have already moved on.
  Future<void> _review(BuildContext context, WidgetRef ref) async {
    final SyncCoordinator? coordinator = ref.read(syncCoordinatorProvider);
    if (coordinator == null) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    final SyncMergePlan? plan = await coordinator.previewMerge();

    if (plan == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not read your account. Try again in a moment.'),
        ),
      );
      return;
    }
    await navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'sync_merge'),
        builder: (BuildContext context) => SyncMergeScreen(plan: plan),
      ),
    );
  }

  static IconData _iconFor(SyncStatus status, SyncRunResult? last) {
    if (status.state == SyncState.offline) return Icons.cloud_off_outlined;
    if (status.state == SyncState.failed) return Icons.error_outline;
    if (last?.outcome == SyncRunOutcome.reviewNeeded) {
      return Icons.help_outline;
    }
    return Icons.cloud_done_outlined;
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.palette.textTertiary,
            height: 1.5,
          ),
    );
  }
}
