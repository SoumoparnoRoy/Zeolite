import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/launch/launch_painter.dart';
import 'package:zeolite/features/launch/launch_screen.dart';
import 'package:zeolite/features/launch/welcome_screen.dart';
import 'package:zeolite/state/auth_providers.dart';
import 'package:zeolite/state/providers.dart';

class _FirstRun extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

class _Returning extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(
        welcomeShown: true,
        onboarded: true,
      );
}

Widget _app(SettingsController Function() settings, VoidCallback onFinished) {
  return ProviderScope(
    overrides: [
      settingsProvider.overrideWith(settings),
      signedInUserProvider.overrideWith(
        (Ref ref) => Stream<User?>.value(null),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? _) {
          final AppSettings? value = ref.watch(settingsProvider).value;
          if (value == null) return const SizedBox.shrink();
          return LaunchScreen(settings: value, onFinished: onFinished);
        },
      ),
    ),
  );
}

/// Nothing here can settle: the welcome screen's crystal never stops.
Future<void> _playOut(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 7));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // The default test font gives every glyph a square em box, which turns
    // two lines of terms into four and makes any measurement of this screen
    // meaningless.
    final FontLoader loader = FontLoader(AppFonts.sans);
    for (final String weight in <String>['Medium', 'SemiBold', 'ExtraBold']) {
      loader.addFont(rootBundle
          .load('assets/fonts/PlusJakartaSans-$weight.ttf'));
    }
    await loader.load();
  });

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('a first run ends on the three ways in', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_FirstRun.new, () {}));
    await _playOut(tester);

    expect(find.text(WelcomeCopy.createLabel), findsOneWidget);
    expect(find.text(WelcomeCopy.signInLabel), findsOneWidget);
    expect(find.text(WelcomeCopy.continueLabel), findsOneWidget);
    // Without this the last choice reads as a limited trial.
    expect(find.text(WelcomeCopy.caption), findsOneWidget);
  });

  testWidgets('carrying on without an account answers the screen for good',
      (WidgetTester tester) async {
    bool finished = false;
    await tester.pumpWidget(_app(_FirstRun.new, () => finished = true));
    await _playOut(tester);

    await tester.tap(find.text(WelcomeCopy.continueLabel));
    // This harness keeps the launch screen, and its clock, mounted.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(finished, isTrue);
    expect((await SettingsService().load()).welcomeShown, isTrue);
    // The choice is not setup: onboarding still has to run.
    expect((await SettingsService().load()).onboarded, isFalse);
  });

  testWidgets('the bottom stack fits a short phone', (WidgetTester tester) async {
    // The three buttons, the terms couplet and the caption are the part of
    // this screen most likely to run off the bottom, and a tablet never shows
    // it. An overflow fails this test on its own.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_FirstRun.new, () {}));
    await _playOut(tester);

    expect(find.text(WelcomeCopy.createLabel), findsOneWidget);
    expect(find.text(WelcomeCopy.caption), findsOneWidget);
  });

  testWidgets('a device with animations off gets the last frame, not a scramble',
      (WidgetTester tester) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(_app(_FirstRun.new, () {}));
    // One frame past the settings load: the choices are already there, rather
    // than five seconds of sequence replayed at a twentieth of its length.
    await tester.pump();
    await tester.pump();

    expect(find.text(WelcomeCopy.createLabel), findsOneWidget);
    expect(find.text(WelcomeCopy.continueLabel), findsOneWidget);
  });

  testWidgets('the sequence has the whole screen to paint on, from the start',
      (WidgetTester tester) async {
    // The Stack collapsed to nothing while the copy was still hidden, so the
    // painter drew into a zero canvas for the whole animation. Every other
    // test asserts the end state, the one moment it does not happen.
    await tester.pumpWidget(_app(_FirstRun.new, () {}));
    await tester.pump();

    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final Duration at in <Duration>[
      const Duration(milliseconds: 400),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
    ]) {
      await tester.pump(at);
      expect(
        tester.getSize(find.byWidgetPredicate(
            (Widget w) => w is CustomPaint && w.painter is LaunchPainter)),
        screen,
        reason: 'the painter lost the screen at ${at.inMilliseconds}ms',
      );
    }
  });

  testWidgets('a later launch never asks again', (WidgetTester tester) async {
    bool finished = false;
    await tester.pumpWidget(_app(_Returning.new, () => finished = true));
    await tester.pumpAndSettle();

    expect(find.text(WelcomeCopy.createLabel), findsNothing);
    expect(find.text(WelcomeCopy.continueLabel), findsNothing);
    expect(finished, isTrue);
  });
}
