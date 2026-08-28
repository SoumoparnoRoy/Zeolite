import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Settings now promises the data stays put *unless Notion is connected*. The
/// manifest decides half of that; the absence of any other caller decides the rest.
void main() {
  final File manifest =
      File('android/app/src/main/AndroidManifest.xml');
  final File settings =
      File('lib/features/settings/settings_screen.dart');

  RegExp removed(String permission) => RegExp(
        'android.permission.$permission"\\s*\\n\\s*tools:node="remove"',
      );

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

  test('the release build asks for INTERNET and nothing more', () {
    final String xml = manifest.readAsStringSync();

    expect(xml,
        contains('<uses-permission android:name="android.permission.INTERNET" />'));
    expect(removed('INTERNET').hasMatch(xml), isFalse,
        reason: 'Notion sync cannot reach the network without it');
    expect(removed('ACCESS_NETWORK_STATE').hasMatch(xml), isTrue);
  });

  test('the promise in Settings is the one being kept', () {
    expect(settings.readAsStringSync(),
        contains('stays on this device unless you connect Notion'));
  });

  test('nothing outside the sync layer can open a socket', () {
    // With the permission granted, "no network" is no longer a build property
    // and has to be one of the code instead.
    const List<String> allowed = <String>[
      'lib/services/notion/',
      'lib/services/sync/',
    ];
    final RegExp caller = RegExp(r'package:http/|\bHttpClient\b|\bSocket\b');

    final Iterable<File> sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'));

    for (final File source in sources) {
      final String path = source.path.replaceAll(r'\', '/');
      if (allowed.any(path.contains)) continue;
      expect(caller.hasMatch(source.readAsStringSync()), isFalse,
          reason: '$path reaches the network outside the sync layer');
    }
  });
}
