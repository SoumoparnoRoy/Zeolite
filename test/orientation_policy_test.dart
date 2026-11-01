import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/orientation_policy.dart';

void main() {
  const List<DeviceOrientation> portrait = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  test('a phone stays portrait, up to just under 600dp', () {
    expect(orientationsFor(360), portrait);
    // Pixel 9: 1080px at 2.625.
    expect(orientationsFor(1080 / 2.625), portrait);
    expect(orientationsFor(599.9), portrait);
  });

  test('from 600dp the display turns all four ways', () {
    expect(orientationsFor(600), DeviceOrientation.values);
    expect(orientationsFor(800), DeviceOrientation.values);
  });

  group('OrientationPolicy', () {
    // Every list sent to Android, in order. The real platform call, so a
    // second caller anywhere in the tree would show up here too.
    late List<List<String>> sent;

    Future<void> startOn(WidgetTester tester) async {
      sent = <List<String>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            sent.add((call.arguments as List<Object?>).cast<String>());
          }
          return null;
        },
      );
      final OrientationPolicy policy = await OrientationPolicy.start();
      addTearDown(() {
        tester.binding.removeObserver(policy);
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
    }

    List<String> names(List<DeviceOrientation> orientations) =>
        orientations.map((DeviceOrientation o) => o.toString()).toList();

    void setDisplay(WidgetTester tester, Size physical, double ratio) {
      tester.view.display.size = physical;
      tester.view.display.devicePixelRatio = ratio;
      tester.view.physicalSize = physical;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
    }

    testWidgets('a narrow split-screen window on a tablet is not locked',
        (WidgetTester tester) async {
      setDisplay(tester, const Size(2560, 1600), 2);
      // A third of the screen: 320dp wide, well under the line.
      tester.view.physicalSize = const Size(640, 1600);

      await startOn(tester);

      expect(sent, <List<String>>[names(DeviceOrientation.values)]);
    });

    testWidgets('a foldable switches once when it opens, not on rotation',
        (WidgetTester tester) async {
      setDisplay(tester, const Size(1080, 2092), 2.625);
      await startOn(tester);
      expect(sent, <List<String>>[names(portrait)]);

      // Unfolded: the inner display is about 700dp on its short side.
      tester.view.display.size = const Size(2208, 1840);
      tester.view.physicalSize = const Size(2208, 1840);
      await tester.pump();
      // Turning the inner display swaps its sides; the short side stays.
      tester.view.display.size = const Size(1840, 2208);
      tester.view.physicalSize = const Size(1840, 2208);
      await tester.pump();

      expect(sent, <List<String>>[
        names(portrait),
        names(DeviceOrientation.values),
      ]);
    });

    testWidgets('a display with no size yet is left alone',
        (WidgetTester tester) async {
      setDisplay(tester, Size.zero, 2.625);
      await startOn(tester);
      expect(sent, isEmpty);

      tester.view.display.size = const Size(2560, 1600);
      await tester.pump();
      expect(sent, <List<String>>[names(DeviceOrientation.values)]);
    });

    testWidgets('only startup sets it: routes, sheets and dialogs never do',
        (WidgetTester tester) async {
      setDisplay(tester, const Size(1080, 2424), 2.625);
      await startOn(tester);
      expect(sent, hasLength(1));

      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('home')),
      ));
      final BuildContext context = navigator.currentContext!;

      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('page')),
      )));
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      unawaited(showModalBottomSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 200, child: Text('sheet')),
      ));
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      unawaited(showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('dialog')),
      ));
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      unawaited(showDatePicker(
        context: context,
        firstDate: DateTime(2026),
        lastDate: DateTime(2027),
        initialDate: DateTime(2026, 11),
      ));
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      // The keyboard and a sideways window both arrive as metrics changes.
      tester.view.viewInsets = const FakeViewPadding(bottom: 800);
      await tester.pump();
      tester.view.resetViewInsets();
      tester.view.physicalSize = const Size(2424, 1080);
      tester.view.display.size = const Size(2424, 1080);
      await tester.pump();

      expect(sent, <List<String>>[names(portrait)]);
    });
  });

  group('nothing else can change it', () {
    final List<File> sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();

    String path(File f) => f.path.replaceAll(r'\', '/');

    test('only the policy sets orientations, and only main starts it', () {
      final List<String> setters = <String>[
        for (final File f in sources)
          if (f.readAsStringSync().contains('setPreferredOrientations'))
            path(f),
      ];
      expect(setters, <String>['lib/core/orientation_policy.dart']);

      List<String> calling(String code) => <String>[
            for (final File f in sources)
              if (f.readAsStringSync().contains(code)) path(f),
          ];
      expect(calling('OrientationPolicy.start('), <String>['lib/main.dart']);
      expect(calling('OrientationPolicy()'),
          <String>['lib/core/orientation_policy.dart']);
    });

    test('the manifest neither locks nor recreates on rotation', () {
      final String xml =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      // A manifest lock letterboxes older tablets, which honour it.
      expect(xml, isNot(contains('screenOrientation')));
      final String activity =
          RegExp(r'<activity\s[^>]*android:name="\.MainActivity"[^>]*>')
              .firstMatch(xml)!
              .group(0)!;
      final String changes = RegExp('android:configChanges="([^"]*)"')
          .firstMatch(activity)!
          .group(1)!;
      expect(
        changes.split('|'),
        containsAll(<String>[
          'orientation',
          'screenSize',
          'smallestScreenSize',
          'screenLayout',
        ]),
      );
    });
  });
}
