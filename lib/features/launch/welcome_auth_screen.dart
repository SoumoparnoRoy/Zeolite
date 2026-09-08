import 'package:flutter/material.dart';

import '../../widgets/gradient_header.dart';
import '../settings/auth_form.dart';

/// Where two of the welcome screen's three choices land. The button that got
/// you here has already said which you meant, so [AuthForm] runs with its
/// toggle off and only the title differs.
///
/// On the app's own header rather than a plain [AppBar]: the theme's bar is
/// white on the gradient every other pushed screen carries, which over a bare
/// scaffold left the title unreadable in the light palette.
class WelcomeAuthScreen extends StatelessWidget {
  const WelcomeAuthScreen({super.key, required this.creating});

  final bool creating;

  static const String createTitle = 'Create a new account';
  static const String signInTitle = 'Already have an account';

  @override
  Widget build(BuildContext context) {
    return PushScaffold(
      title: creating ? createTitle : signInTitle,
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          sliver: SliverList.list(
            children: <Widget>[
              AuthForm(
                startCreating: creating,
                allowToggle: false,
                onAuthenticated: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
