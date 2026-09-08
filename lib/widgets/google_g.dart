import 'package:flutter/material.dart';

/// Google's four-colour G for the sign-in button — their asset with its
/// backing tile keyed out, not a drawing of it: a reconstruction of a mark
/// this familiar reads as wrong however carefully it is measured.
class GoogleG extends StatelessWidget {
  const GoogleG({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icon/google_g.png',
      width: size,
      height: size,
      // The button already says "Continue with Google" beside it.
      excludeFromSemantics: true,
    );
  }
}
