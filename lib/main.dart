import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/app_theme.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _registerFontLicences();

  // Options come from google-services.json via the Gradle plugin rather than a
  // generated firebase_options.dart: this ships Android only, and one config
  // file is one fewer thing to keep in step. A failure must not block launch —
  // everything except sync works with no Firebase at all.
  try {
    await Firebase.initializeApp();
  } catch (error) {
    debugPrint('Firebase unavailable, continuing offline: $error');
  }

  // Set the chrome dark before the first frame so launch never flashes light.
  // Once MaterialApp is up its AppBarTheme takes over and follows whichever
  // theme the user chose.
  SystemChrome.setSystemUIOverlayStyle(
    AppTheme.overlayStyleFor(AppPalette.dark),
  );
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Notification setup is best-effort — a failure here must never block
  // launch, so the service swallows and logs its own errors.
  await NotificationService.instance.init();

  runApp(const ProviderScope(child: ZeoliteApp()));
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
