import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'firebase/firebase_emulator.dart';

/// Turns usage measurement and crash reporting on or off. Both start off in
/// the manifest, so nothing is sent before the person has answered.
abstract class CollectionSwitches {
  Future<void> apply({required bool usage, required bool crashes});
}

class FirebaseCollectionSwitches implements CollectionSwitches {
  const FirebaseCollectionSwitches();

  /// Read by the Dart error sink: Crashlytics keeps what it is given while off
  /// and sends it after a later yes.
  static bool crashesOn = false;

  @override
  Future<void> apply({required bool usage, required bool crashes}) async {
    // Debug and profile builds keep their failures to the log: a crash on the
    // development tablet is not a user's.
    final bool sendCrashes = crashes && kReleaseMode;
    crashesOn = sendCrashes;
    await FirebaseAnalytics.instance
        .setAnalyticsCollectionEnabled(usage && !firebaseEmulatorInUse);
    await FirebaseCrashlytics.instance
        .setCrashlyticsCollectionEnabled(sendCrashes);
    if (!sendCrashes) await FirebaseCrashlytics.instance.deleteUnsentReports();
  }
}

class NoCollectionSwitches implements CollectionSwitches {
  const NoCollectionSwitches();

  @override
  Future<void> apply({required bool usage, required bool crashes}) async {}
}
