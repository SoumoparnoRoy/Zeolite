import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Starts App Check once, after an adult's yes rather than at launch: with
/// auto-refresh on, activating can fetch a token from Google straight away.
abstract class AppCheckStarter {
  Future<void> activate();
}

class FirebaseAppCheckStarter implements AppCheckStarter {
  bool _activated = false;

  @override
  Future<void> activate() async {
    if (_activated) return;
    _activated = true;
    // Play Integrity only vouches for a build Play would recognise, so the
    // debug and profile builds sideloaded for testing use a registered debug
    // token instead.
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kReleaseMode
          ? const AndroidPlayIntegrityProvider()
          : const AndroidDebugProvider(),
    );
  }
}

class NoAppCheckStarter implements AppCheckStarter {
  const NoAppCheckStarter();

  @override
  Future<void> activate() async {}
}
