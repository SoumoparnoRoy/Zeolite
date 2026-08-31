import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Settings now promises the data stays put *unless Notion is connected*. The
/// manifest decides half of that; the absence of any other caller decides the rest.
void main() {
  final File manifest =
      File('android/app/src/main/AndroidManifest.xml');
  final File settings =
      File('lib/features/settings/settings_screen.dart');

  /// Takes a full permission name: the ones a dependency drags in are not all
  /// under `android.permission`.
  RegExp removed(String permission) => RegExp(
        '$permission"\\s*\\n\\s*tools:node="remove"',
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
    expect(removed('android.permission.INTERNET').hasMatch(xml), isFalse,
        reason: 'Notion sync cannot reach the network without it');
    // Analytics disables itself without this and says so only in logcat.
    expect(
      xml,
      contains(
          '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />'),
    );

    // Everything a dependency drags in that this app has no use for. Analytics
    // arrives with the whole advertising stack, and a listing saying an
    // attendance app measures ad campaigns invites the question. The merged
    // manifest is where these actually resolve, so a build stays the check that
    // matters — this holds the intent in place between builds.
    for (final String unwanted in <String>[
      'android.permission.ACCESS_ADSERVICES_ATTRIBUTION',
      'android.permission.ACCESS_ADSERVICES_AD_ID',
      'com.google.android.gms.permission.AD_ID',
      'com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE',
      // Arrived with the secure store, and caught in the merged manifest —
      // this file cannot see what a dependency contributes.
      'android.permission.USE_BIOMETRIC',
      'android.permission.USE_FINGERPRINT',
    ]) {
      expect(removed(unwanted).hasMatch(xml), isTrue, reason: unwanted);
    }
    // Removing the permission does not stop the SDK asking for the id.
    expect(
      xml,
      contains('android:name="google_analytics_adid_collection_enabled"'),
    );
  });

  test('the promise in Settings names both ways data leaves', () {
    final String source = settings.readAsStringSync();

    // In the pieces the source wraps into: this reads the file, not the
    // rendered string.
    expect(source, contains('stay on this device unless '));
    expect(source, contains('you sign in or connect Notion.'));
    // Naming only Notion was false for every signed-in user once Firestore
    // sync landed, and naming only those two was false for everybody once
    // Analytics did: it reports on every install, account or not.
    expect(source, contains('counts how the app '));
    expect(source,
        isNot(contains('stays on this device unless you connect Notion')));
    expect(source, isNot(contains('Your data stays on this device unless')));
    expect(source, isNot(contains('everything stays on this device')));
  });

  test('nothing outside the sync layer can open a socket', () {
    // With the permission granted, "no network" is no longer a build property
    // and has to be one of the code instead.
    const List<String> allowed = <String>[
      'lib/services/firebase/',
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
