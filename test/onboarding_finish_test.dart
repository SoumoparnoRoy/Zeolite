import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/words.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/onboarding/onboarding_screen.dart';
import 'package:zeolite/state/auth_providers.dart';
import 'package:zeolite/state/providers.dart';

import 'slider_drag.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('finishing setup keeps what the welcome screen settled',
      (WidgetTester tester) async {
    await SettingsService().save(
      const AppSettings(
        welcomeShown: true,
        accentColour: AccentColour.teal,
        launchAnimation: LaunchAnimation.short,
      ),
    );

    // Signed out rather than left to reach Firebase, which the save path
    // watches through the sync target.
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signedInUserProvider.overrideWith(
          (Ref ref) => Stream<User?>.value(null),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const OnboardingScreen(),
        ),
      ),
    );

    // Off, so finishing does not reach the notification permission channel.
    await tester.scrollUntilVisible(find.byType(Switch), 200);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.text('Start tracking'));
    // Not settled: the button spins until the shell replaces this screen, so
    // the screen is taken down here the way the app would replace it.
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    final AppSettings saved = await SettingsService().load();
    expect(saved.onboarded, isTrue);
    expect(saved.termStart, isNotNull);
    expect(saved.welcomeShown, isTrue);
    expect(saved.accentColour, AccentColour.teal);
    expect(saved.launchAnimation, LaunchAnimation.short);
  });

  testWidgets('the target slider follows the drag and finishes with it',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signedInUserProvider.overrideWith(
          (Ref ref) => Stream<User?>.value(null),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder slider = find.byType(Slider);
    final (TestGesture drag, double finger) =
        await dragSlider(tester, slider, 120);
    expectThumbUnderFinger(tester, slider, finger, steps: 100);
    await drag.up();
    await tester.pumpAndSettle();
    final double shown = tester.widget<Slider>(slider).value;
    expect(find.text(Words.percent(shown)), findsOneWidget);

    await tester.scrollUntilVisible(find.byType(Switch), 200);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.text('Start tracking'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    final AppSettings saved = await SettingsService().load();
    expect(saved.targetPercent, shown);
    expect(saved.targetPercent, saved.targetPercent.round());
  });

  testWidgets('the target runs from 0, and the lowest pick is 1',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signedInUserProvider.overrideWith(
          (Ref ref) => Stream<User?>.value(null),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder slider = find.byType(Slider);

    final double at75 = thumbX(tester, slider);
    final double at100 = await dragAndRelease(tester, slider, 4000);
    final double at1 = await dragAndRelease(tester, slider, -4000);

    expectThreeQuarters(at1, at75, at100);
    expect(find.text('1%'), findsOneWidget);

    await tester.scrollUntilVisible(find.byType(Switch), 200);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.text('Start tracking'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    expect((await SettingsService().load()).targetPercent, 1);
  });
}
