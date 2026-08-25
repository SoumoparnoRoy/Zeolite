import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Settings promises "All your data stays on this device", and it is the
/// manifest, not any Dart, that decides whether that is true.
void main() {
  final File manifest =
      File('android/app/src/main/AndroidManifest.xml');
  final File settings =
      File('lib/features/settings/settings_screen.dart');

  test('the manifest refuses both ways data leaves the device', () {
    final String xml = manifest.readAsStringSync();

    expect(xml, contains('android:allowBackup="false"'));
    // Android 12+ transfers device to device, which allowBackup does not cover.
    expect(xml, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));

    final File rules =
        File('android/app/src/main/res/xml/data_extraction_rules.xml');
    expect(rules.existsSync(), isTrue);
    final String extraction = rules.readAsStringSync();
    expect(extraction, contains('<cloud-backup>'));
    expect(extraction, contains('<device-transfer>'));
    expect(RegExp('<exclude domain="database" />').allMatches(extraction),
        hasLength(2));
  });

  test('the release build asks for no network permission', () {
    final String xml = manifest.readAsStringSync();
    for (final String permission in <String>['INTERNET', 'ACCESS_NETWORK_STATE']) {
      final RegExp declared = RegExp(
        'android.permission.$permission"\\s*\\n\\s*tools:node="remove"',
      );
      expect(declared.hasMatch(xml), isTrue,
          reason: '$permission must be removed, not merely unused');
    }
  });

  test('the promise in Settings is the one being kept', () {
    expect(settings.readAsStringSync(), contains('stays on this device'));
  });
}
