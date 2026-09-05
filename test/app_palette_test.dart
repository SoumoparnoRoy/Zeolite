import 'dart:math' as math;

import 'package:zeolite/core/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG relative-luminance contrast ratio. Used to keep the light palette
/// honest: a colour that reads on black is frequently unreadable on white.
double _contrast(Color a, Color b) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final double la = luminance(a);
  final double lb = luminance(b);
  final double hi = math.max(la, lb);
  final double lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('palettes', () {
    test('carry their own brightness', () {
      expect(AppPalette.dark.isDark, isTrue);
      expect(AppPalette.light.isDark, isFalse);
      expect(AppPalette.light.brightness, Brightness.light);
    });

    test('light is not merely dark with the surfaces swapped', () {
      // Every status colour must be retuned, otherwise they glow on white.
      expect(AppPalette.light.present, isNot(AppPalette.dark.present));
      expect(AppPalette.light.absent, isNot(AppPalette.dark.absent));
      expect(AppPalette.light.warning, isNot(AppPalette.dark.warning));
      expect(AppPalette.light.cancelled, isNot(AppPalette.dark.cancelled));
      expect(AppPalette.light.accent, isNot(AppPalette.dark.accent));
    });

    test('elevation runs the correct way in each theme', () {
      // Dark: raised surfaces get lighter. Light: the canvas is the tinted
      // layer and cards sit brighter on top of it.
      expect(AppPalette.dark.surface.r, greaterThan(AppPalette.dark.canvas.r));
      expect(
        AppPalette.light.surface.r,
        greaterThan(AppPalette.light.canvas.r),
      );
    });

    test('body text stays readable on its own surface', () {
      for (final AppPalette p in <AppPalette>[
        AppPalette.dark,
        AppPalette.light,
      ]) {
        // 4.5:1 is the WCAG AA threshold for body text.
        expect(
          _contrast(p.textPrimary, p.surface),
          greaterThan(4.5),
          reason: 'textPrimary on surface (${p.brightness})',
        );
        expect(
          _contrast(p.textSecondary, p.surface),
          greaterThan(4.5),
          reason: 'textSecondary on surface (${p.brightness})',
        );
      }
    });

    test('status colours carry against the surface they are drawn on', () {
      for (final AppPalette p in <AppPalette>[
        AppPalette.dark,
        AppPalette.light,
      ]) {
        for (final Color c in <Color>[
          p.present,
          p.absent,
          p.warning,
          p.cancelled,
        ]) {
          // 3:1 is the WCAG threshold for large text and graphical objects,
          // which is what these are used for.
          expect(
            _contrast(c, p.surface),
            greaterThan(3.0),
            reason: 'status colour on surface (${p.brightness})',
          );
        }
      }
    });
  });

  group('lerp', () {
    test('flips brightness at the midpoint rather than interpolating it', () {
      final AppPalette before = AppPalette.dark.lerp(AppPalette.light, 0.2);
      final AppPalette after = AppPalette.dark.lerp(AppPalette.light, 0.8);
      expect(before.brightness, Brightness.dark);
      expect(after.brightness, Brightness.light);
    });

    test('returns the endpoints unchanged', () {
      expect(AppPalette.dark.lerp(AppPalette.light, 0).canvas,
          AppPalette.dark.canvas);
      expect(AppPalette.dark.lerp(AppPalette.light, 1).canvas,
          AppPalette.light.canvas);
    });

    test('a non-palette extension leaves it alone', () {
      expect(AppPalette.dark.lerp(null, 0.5), AppPalette.dark);
    });
  });

  group('themes', () {
    test('each publishes its palette as an extension', () {
      final ThemeData dark = AppTheme.dark();
      final ThemeData light = AppTheme.light();
      expect(dark.extension<AppPalette>(), AppPalette.dark);
      expect(light.extension<AppPalette>(), AppPalette.light);
    });

    test('scaffold and brightness follow the palette', () {
      expect(AppTheme.light().brightness, Brightness.light);
      expect(AppTheme.light().scaffoldBackgroundColor, AppPalette.light.canvas);
      expect(AppTheme.dark().scaffoldBackgroundColor, AppPalette.dark.canvas);
    });

    test('a control on a sheet is never painted the sheet colour', () {
      // Light's canvas and surfaceHigh hold the same value, so a control
      // filled with surfaceHigh is invisible on a sheet — which is what a
      // field and a secondary button both were.
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(),
        AppTheme.dark(),
      ]) {
        final Color sheet = theme.bottomSheetTheme.modalBackgroundColor!;
        expect(theme.inputDecorationTheme.fillColor, isNot(sheet));
        // Same rule inside a dialog: the picker's hour and minute are fields.
        expect(
          WidgetStateProperty.resolveAs<Color>(
            theme.timePickerTheme.hourMinuteColor!,
            <WidgetState>{},
          ),
          isNot(theme.dialogTheme.backgroundColor),
          reason: 'time picker field on a dialog (${theme.brightness})',
        );
        expect(
          theme.outlinedButtonTheme.style?.backgroundColor
              ?.resolve(<WidgetState>{}),
          isNot(sheet),
          reason: 'outlined button on a sheet (${theme.brightness})',
        );
      }
    });

    test('status bar icons invert between themes', () {
      expect(
        AppTheme.overlayStyleFor(AppPalette.dark).statusBarIconBrightness,
        Brightness.light,
      );
      expect(
        AppTheme.overlayStyleFor(AppPalette.light).statusBarIconBrightness,
        Brightness.dark,
      );
    });
  });

  group('subject ink', () {
    test('every stored subject colour becomes readable on a card', () {
      // The palette is picked for identity on a tile, not for legibility as
      // text: lime on white is about 1.5:1 raw.
      for (final AppPalette p in <AppPalette>[
        AppPalette.dark,
        AppPalette.light,
      ]) {
        for (final int value in AppColors.subjectPalette) {
          final Color ink = AppColors.inkOn(Color(value), p);
          expect(
            _contrast(ink, p.surface),
            greaterThanOrEqualTo(4.5),
            reason: '${value.toRadixString(16)} on ${p.brightness}',
          );
        }
      }
    });

    test('keeps the hue, so a subject stays recognisable', () {
      const Color lime = Color(0xFF9BE36D);
      final double before = HSLColor.fromColor(lime).hue;
      for (final AppPalette p in <AppPalette>[
        AppPalette.dark,
        AppPalette.light,
      ]) {
        final double after = HSLColor.fromColor(AppColors.inkOn(lime, p)).hue;
        expect((after - before).abs(), lessThan(1));
      }
    });
  });
}
