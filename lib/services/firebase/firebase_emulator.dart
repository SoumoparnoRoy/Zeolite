import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// `--dart-define=ZEOLITE_FIREBASE_EMULATOR=localhost`. FlutterFire maps it to
/// 10.0.2.2, which only an Android emulator can reach.
const String _emulatorHost =
    String.fromEnvironment('ZEOLITE_FIREBASE_EMULATOR');

/// Analytics has no emulator, so a build pointed at one never measures,
/// whatever the stored choice says.
const bool firebaseEmulatorInUse = !kReleaseMode && _emulatorHost != '';

/// Before any Auth or Firestore call.
Future<void> useFirebaseEmulatorIfAsked() async {
  if (!firebaseEmulatorInUse) return;
  await FirebaseAuth.instance.useAuthEmulator(_emulatorHost, 9099);
  FirebaseFirestore.instance.useFirestoreEmulator(_emulatorHost, 8085);
  await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(false);
}
