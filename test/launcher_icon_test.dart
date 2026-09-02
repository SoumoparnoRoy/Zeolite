import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/launcher_icon_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The wire names are the contract between three files that nothing links
  // together: the enum, the manifest, and the Kotlin list. A name that exists
  // in one and not the others fails at the tap, on a device, silently.
  test('every icon names an activity-alias the manifest declares', () {
    final String manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final LauncherIcon icon in LauncherIcon.values) {
      final String alias =
          '.Launcher${icon.wire[0].toUpperCase()}${icon.wire.substring(1)}';
      expect(
        manifest,
        contains('android:name="$alias"'),
        reason: '${icon.name} has no alias in the manifest',
      );
    }
  });

  test('every icon has the preview the picker draws', () {
    for (final LauncherIcon icon in LauncherIcon.values) {
      expect(File(icon.preview).existsSync(), isTrue, reason: icon.preview);
    }
  });

  test('a wire name that is not ours falls back rather than throwing', () {
    expect(LauncherIcon.fromWire('teal'), LauncherIcon.teal);
    expect(LauncherIcon.fromWire('chartreuse'), LauncherIcon.standard);
    expect(LauncherIcon.fromWire(null), LauncherIcon.standard);
  });

  test('the platform is asked for the icon by its wire name', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('zeolite/launcher_icon'),
      (MethodCall call) async {
        calls.add(call);
        return call.method == 'current' ? 'plum' : null;
      },
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('zeolite/launcher_icon'), null));

    const LauncherIconService service = LauncherIconService();
    expect(await service.current(), LauncherIcon.plum);
    await service.select(LauncherIcon.slate);
    expect(calls.last.arguments, <String, Object?>{'icon': 'slate'});
  });

  // Every platform but Android answers nothing at all, and the picker still
  // has to show something.
  test('no platform side means the default, not a crash', () async {
    expect(await const LauncherIconService().current(), LauncherIcon.standard);
  });
}
