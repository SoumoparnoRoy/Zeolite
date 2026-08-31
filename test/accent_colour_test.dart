import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/settings/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('violet is exactly what the app already shipped', () {
    for (final AppPalette base in <AppPalette>[
      AppPalette.dark,
      AppPalette.light,
    ]) {
      final AppPalette tinted = base.withAccent(AccentColour.violet);
      expect(tinted.accent, base.accent);
      expect(tinted.accentSoft, base.accentSoft);
      expect(tinted.gradientTop, base.gradientTop);
      expect(tinted.gradientMid, base.gradientMid);
      expect(tinted.gradientBottom, base.gradientBottom);
      expect(tinted.cardShadow, base.cardShadow);
    }
  });

  test('every accent is defined in both brightnesses, and moves the tint', () {
    for (final AccentColour accent in AccentColour.values) {
      for (final AppPalette base in <AppPalette>[
        AppPalette.dark,
        AppPalette.light,
      ]) {
        // A missing entry would throw on the null assertion rather than fall
        // back, so this is the check that the table is complete.
        final AppPalette tinted = base.withAccent(accent);
        if (accent != AccentColour.violet) {
          expect(tinted.accent, isNot(base.accent), reason: accent.name);
        }
        // Only the tint moves: the surfaces and the status colours are what
        // the rest of the app reads for meaning.
        expect(tinted.canvas, base.canvas);
        expect(tinted.present, base.present);
        expect(tinted.absent, base.absent);
        expect(tinted.textPrimary, base.textPrimary);
      }
    }
  });

  test('the chosen accent survives a restart', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final SettingsService service = SettingsService();

    await service.save(
      (await service.load()).copyWith(accentColour: AccentColour.teal),
    );
    expect((await service.load()).accentColour, AccentColour.teal);
  });

  test('an accent written by a newer build reads back as the default', () {
    expect(AccentColour.fromName('chartreuse'), AccentColour.violet);
    expect(AccentColour.fromName(null), AccentColour.violet);
  });
}
