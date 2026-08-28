import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart';
import '../../domain/sync/sync_status.dart';
import '../../domain/sync/sync_target.dart';
import '../../services/auth_service.dart';
import '../../services/sync/sync_coordinator.dart';
import '../../state/auth_providers.dart';
import '../../state/sync_providers.dart';
import '../../widgets/common.dart';
import '../../widgets/gradient_header.dart';

/// Signing in is optional and buys backup, sync across devices, and Notion.
/// Everything else works signed out and always has, so this screen never
/// stands between anyone and their attendance.
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
                    ? const _SignInForm()
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
      messenger.showSnackBar(SnackBar(content: Text(_phrase(result.failure!))));
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

class _SignInForm extends ConsumerStatefulWidget {
  const _SignInForm();

  @override
  ConsumerState<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends ConsumerState<_SignInForm> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _busy = false;

  /// One form for both, because the only difference is which call it makes and
  /// a separate sign-up screen would double the layout to save a sentence.
  bool _creating = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<AuthResult> Function() call) async {
    setState(() => _busy = true);
    final AuthResult result = await call();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok && result.failure != AuthFailure.cancelled) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_phrase(result.failure!))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthService auth = ref.read(authServiceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _Hint(
          'An account backs your attendance up and keeps it the same on every '
          'device you sign in on. Zeolite works without one.',
        ),
        const SizedBox(height: AppSpacing.md),
        SurfaceCard(
          child: Column(
            children: <Widget>[
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(() => _creating
                  ? auth.signUp(_email.text, _password.text)
                  : auth.signIn(_email.text, _password.text)),
          child: Text(_creating ? 'Create account' : 'Sign in'),
        ),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _creating = !_creating),
          child: Text(_creating
              ? 'I already have an account'
              : 'Create an account instead'),
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(auth.signInWithGoogle),
          icon: const Icon(Icons.account_circle_outlined, size: 18),
          label: const Text('Continue with Google'),
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
                  syncStatusLine(status, last),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
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

  static IconData _iconFor(SyncStatus status, SyncRunResult? last) {
    if (status.state == SyncState.offline) return Icons.cloud_off_outlined;
    if (status.state == SyncState.failed) return Icons.error_outline;
    if (last?.outcome == SyncRunOutcome.reviewNeeded) {
      return Icons.help_outline;
    }
    return Icons.cloud_done_outlined;
  }

}


/// The one line Settings shows for a target. Lifted out of the widget so the
/// wording each state produces can be pinned down without a Firebase user.
@visibleForTesting
String syncStatusLine(SyncStatus status, SyncRunResult? last) {
  switch (status.state) {
    case SyncState.running:
      return 'Syncing…';
    case SyncState.offline:
      return 'No connection. Your attendance is safe on this device.';
    case SyncState.failed:
      return status.failure == SyncFailure.auth
          ? 'Your account would not accept the last sync. Sign out and back '
              'in, then try again.'
          : 'The last sync did not finish. Nothing on this device changed.';
    case SyncState.idle:
      if (last?.outcome == SyncRunOutcome.reviewNeeded) {
        // The coordinator refuses to merge this case and there is no screen
        // to resolve it yet, so say so rather than showing a bare "synced".
        return 'This device and your account both hold attendance. Nothing '
            'was changed — choosing between them is not built yet.';
      }
      if (status.lastRunAt == null) return 'Not synced yet.';
      return 'Synced ${_ago(status.lastRunAt!)}.${_counts(last)}';
  }
}

String _counts(SyncRunResult? last) {
  if (last == null) return '';
  final List<String> parts = <String>[
    if (last.pushed > 0) '${last.pushed} sent',
    if (last.pulled > 0) '${last.pulled} received',
    if (last.overwritten > 0) '${last.overwritten} replaced there',
  ];
  return parts.isEmpty ? '' : ' ${parts.join(', ')}.';
}

String _ago(DateTime at) {
  final Duration since = DateTime.now().difference(at);
  if (since.inMinutes < 1) return 'just now';
  if (since.inMinutes < 60) return '${since.inMinutes} min ago';
  if (since.inHours < 24) return '${since.inHours} h ago';
  return 'on ${Dates.formatDayMonth(at)}';
}

/// Firebase's codes say what went wrong to a developer, not to whoever is
/// holding the phone.
String _phrase(AuthFailure failure) {
  switch (failure) {
    case AuthFailure.network:
      return 'No connection. Your attendance is safe on this device.';
    case AuthFailure.wrongPassword:
      return 'That email and password do not match.';
    case AuthFailure.noSuchUser:
      return 'No account with that email.';
    case AuthFailure.emailInUse:
      return 'That email already has an account. Sign in instead.';
    case AuthFailure.weakPassword:
      return 'Pick a longer password — at least six characters.';
    case AuthFailure.invalidEmail:
      return 'That does not look like an email address.';
    case AuthFailure.differentSignInMethod:
      return 'That email was registered a different way. Try Continue with '
          'Google.';
    case AuthFailure.needsRecentLogin:
      return 'Sign out and back in first, then delete the account.';
    case AuthFailure.cancelled:
    case AuthFailure.unknown:
      return 'That did not work. Try again.';
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
