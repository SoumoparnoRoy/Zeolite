import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/app_theme.dart';
import 'core/report_error.dart';
import 'services/firebase/firebase_emulator.dart';
import 'services/notification_service.dart';
import 'state/home_widget_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _routeUncaughtErrors();
  _registerFontLicences();

  // Options come from google-services.json via the Gradle plugin rather than a
  // generated firebase_options.dart: this ships Android only, and one config
  // file is one fewer thing to keep in step. A failure must not block launch —
  // everything except sync works with no Firebase at all.
  try {
    await Firebase.initializeApp();
    // Play Integrity only vouches for a build Play would recognise, so the
    // debug and profile builds sideloaded for testing use a registered debug
    // token instead.
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kReleaseMode
          ? const AndroidPlayIntegrityProvider()
          : const AndroidDebugProvider(),
    );
    // Debug and profile builds keep their failures to the log: a crash on the
    // development tablet is not a user's.
    await FirebaseCrashlytics.instance
        .setCrashlyticsCollectionEnabled(kReleaseMode);
    if (kReleaseMode) errorSink = _toCrashlytics;
    await useFirebaseEmulatorIfAsked();
  } catch (error, stack) {
    reportError(error, stack, where: 'Firebase start-up');
  }

  // The stored choice is not readable this early, so the chrome follows the
  // system for one frame. Launch then annotates its own once settings land.
  SystemChrome.setSystemUIOverlayStyle(
    AppTheme.overlayStyleFor(
      PlatformDispatcher.instance.platformBrightness == Brightness.light
          ? AppPalette.light
          : AppPalette.dark,
    ),
  );
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Notification setup is best-effort — a failure here must never block
  // launch, so the service swallows and logs its own errors.
  await NotificationService.instance.init(
    backgroundAction: handleNotificationAction,
  );

  // Stores the callback handles Android needs to reach Dart from a widget tap.
  // Cheap, and it has to happen before the first tap rather than before the
  // first frame.
  unawaited(registerHomeWidgetCallbacks());

  runApp(const ProviderScope(child: ZeoliteApp()));
}

/// The type and the stack, never the message: an exception's text can quote
/// what it failed on, and that may be something the user typed.
void _toCrashlytics(Object error, StackTrace? stack, String where) {
  unawaited(
    FirebaseCrashlytics.instance.recordError(
      error.runtimeType.toString(),
      stack,
      reason: where,
      fatal: crashIsFatal(where),
    ),
  );
}

/// Only what nothing caught counts as a crash; a caught failure the app
/// carried on past stays a non-fatal. That includes a framework error:
/// Flutter has already caught it, and an overflow or a failed build leaves
/// the app running.
@visibleForTesting
bool crashIsFatal(String where) => where == _uncaught;

const String _uncaught = 'uncaught';
const String _framework = 'Flutter framework';

/// Sends what nothing caught to [reportError], the same place as every caught
/// failure, so the crash reporter behind it sees both.
void _routeUncaughtErrors() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    reportError(details.exception, details.stack, where: _framework);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    reportError(error, stack, where: _uncaught);
    return true;
  };
  // Release builds would otherwise paint a bare grey box where a widget
  // failed to build. Debug keeps Flutter's red screen, which says why.
  if (kReleaseMode) {
    ErrorWidget.builder = (FlutterErrorDetails details) => const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'This part of the screen could not be shown.',
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
            ),
          ),
        );
  }
}

/// The OFL requires its text to travel with the fonts it covers, so the two
/// licence files ship as assets and are read lazily into Flutter's registry
/// rather than being pasted into a source file.
void _registerFontLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final MapEntry<String, String> font in const <String, String>{
      'Plus Jakarta Sans': 'assets/fonts/PlusJakartaSans-OFL.txt',
      'JetBrains Mono': 'assets/fonts/JetBrainsMono-OFL.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks(
        <String>[font.key],
        await rootBundle.loadString(font.value),
      );
    }
  });
}
