import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_theme.dart';
import '../../services/auth_service.dart';
import '../../state/auth_providers.dart';
import '../../widgets/common.dart';

/// The email, password and Google form, shared by Settings › Account and the
/// two screens the welcome screen offers.
///
/// One widget rather than a copy per entry point: [authFailureMessage] already
/// centralises the failure phrasing, and a second form would be a second set
/// of strings to keep in step with it.
class AuthForm extends ConsumerStatefulWidget {
  const AuthForm({
    super.key,
    this.startCreating = false,
    this.allowToggle = true,
    this.onAuthenticated,
  });

  /// Which call the submit button makes to begin with.
  final bool startCreating;

  /// Settings offers both from one screen. The welcome screen sends each to
  /// its own, so the toggle would contradict the button that got you here.
  final bool allowToggle;

  /// Called after a successful sign-in or sign-up.
  final VoidCallback? onAuthenticated;

  @override
  ConsumerState<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends ConsumerState<AuthForm> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  late bool _creating = widget.startCreating;

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
    if (result.ok) {
      widget.onAuthenticated?.call();
      return;
    }
    if (result.failure != AuthFailure.cancelled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(authFailureMessage(result.failure!))),
      );
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
        if (widget.allowToggle)
          TextButton(
            onPressed:
                _busy ? null : () => setState(() => _creating = !_creating),
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

/// Firebase's codes say what went wrong to a developer, not to whoever is
/// holding the phone.
String authFailureMessage(AuthFailure failure) {
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
