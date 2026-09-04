import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/onboarding/onboarding_screen.dart';
import 'package:zeolite/state/auth_providers.dart';
import 'package:zeolite/state/providers.dart';

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
    expect(saved.semesterStart, isNotNull);
    expect(saved.welcomeShown, isTrue);
    expect(saved.accentColour, AccentColour.teal);
    expect(saved.launchAnimation, LaunchAnimation.short);
  });
}
