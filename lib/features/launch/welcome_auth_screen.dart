import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../settings/auth_form.dart';

/// Where two of the welcome screen's three choices land. The button that got
/// you here has already said which you meant, so [AuthForm] runs with its
/// toggle off and only the title differs.
class WelcomeAuthScreen extends StatelessWidget {
  const WelcomeAuthScreen({super.key, required this.creating});

  final bool creating;

  static const String createTitle = 'Create a new account';
  static const String signInTitle = 'Already have an account';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(creating ? createTitle : signInTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: <Widget>[
            AuthForm(
              startCreating: creating,
              allowToggle: false,
              onAuthenticated: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}
