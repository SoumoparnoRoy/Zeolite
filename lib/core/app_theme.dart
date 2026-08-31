import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The colours the app can be tinted with.
///
/// Deliberately none of green, amber or red: those three mean present, tight
/// and absent everywhere else in the app, and an accent wearing one of them
/// reads as carrying a meaning it does not.
enum AccentColour {
  violet('Violet'),
  indigo('Indigo'),
  teal('Teal'),
  magenta('Magenta'),
  slate('Slate');

  const AccentColour(this.label);

  final String label;

  static AccentColour fromName(String? value) {
    for (final AccentColour accent in AccentColour.values) {
      if (accent.name == value) return accent;
    }
    return AccentColour.violet;
  }
}

/// One accent in one brightness: the five colours that carry the app's
/// identity, plus the tint the light theme's card shadow takes.
///
/// Hand-picked per pair rather than rotated from a single hue. The two base
/// palettes are not inversions of each other — light darkens every accent
/// until it holds against a white card — and a rotation throws that away.
@immutable
class _AccentSet {
  const _AccentSet({
    required this.accent,
    required this.soft,
    required this.top,
    required this.mid,
    required this.bottom,
    this.shadow = const Color(0x00000000),
  });

  final Color accent;
  final Color soft;
  final Color top;
  final Color mid;
  final Color bottom;
  final Color shadow;
}

/// The colours that change between themes.
///
/// These live in a [ThemeExtension] rather than as static constants so a single
/// widget tree can be repainted for light or dark without any global mutable
/// state. Read one with `context.palette`.
///
/// Status colours are in here too: `present` at its dark-theme value is far too
/// pale to read as text on a white card, so light gets its own, darker set.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceHigher,
    required this.navSurface,
    required this.outline,
    required this.outlineSoft,
    required this.hairline,
    required this.accent,
    required this.accentSoft,
    required this.cyan,
    required this.gradientTop,
    required this.gradientMid,
    required this.gradientBottom,
    required this.cardShadow,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textFaint,
    required this.present,
    required this.absent,
    required this.cancelled,
    required this.warning,
  });

  final Brightness brightness;

  final Color canvas;
  final Color surface;
  final Color surfaceHigh;
  final Color surfaceHigher;

  /// The bottom navigation bar, which sits a step away from the canvas in both
  /// themes so the tab row reads as chrome rather than as more content.
  final Color navSurface;

  final Color outline;
  final Color outlineSoft;

  /// The one-pixel rule under a day group heading. Lighter than [outlineSoft]
  /// because it divides a list rather than enclosing a shape.
  final Color hairline;

  final Color accent;
  final Color accentSoft;
  final Color cyan;

  /// The violet block that bleeds from the top of every screen. Three stops
  /// rather than two: the tall Today header needs the extra depth at the
  /// bottom, and the shorter headers simply stop before reaching it.
  final Color gradientTop;
  final Color gradientMid;
  final Color gradientBottom;

  /// Card elevation. Transparent in dark, where a lighter fill does the work a
  /// shadow cannot do against near-black.
  final Color cardShadow;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// The faintest usable grey — placeholder rows, chevrons, a weekend column.
  /// Never body text; it does not meet AA and is not meant to.
  final Color textFaint;

  final Color present;
  final Color absent;
  final Color cancelled;
  final Color warning;

  bool get isDark => brightness == Brightness.dark;

  /// The gradient itself, angled the same way on every screen so the headers
  /// look like one object seen at different heights.
  LinearGradient get headerGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[gradientTop, gradientMid, gradientBottom],
        stops: const <double>[0, 0.62, 1],
      );

  /// The same violet as a compact fill for buttons and the FAB, where the
  /// three-stop version has no room to develop.
  LinearGradient get accentGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[gradientTop, gradientMid],
      );

  List<BoxShadow> get cardElevation => cardShadow.a == 0
      ? const <BoxShadow>[]
      : <BoxShadow>[
          BoxShadow(
            color: cardShadow,
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ];

  /// Near-black canvas with layered surfaces for elevation, and a deeper,
  /// less luminous gradient — the light one glows uncomfortably at night.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF0B0B11),
    surface: Color(0xFF16161F),
    surfaceHigh: Color(0xFF1E1E28),
    surfaceHigher: Color(0xFF23232E),
    navSurface: Color(0xFF13131A),
    outline: Color(0xFF2C2C39),
    outlineSoft: Color(0xFF23232E),
    hairline: Color(0xFF23232E),
    accent: Color(0xFFA28FFF),
    accentSoft: Color(0xFF2A2542),
    cyan: Color(0xFF4FD6D2),
    gradientTop: Color(0xFF5B45E8),
    gradientMid: Color(0xFF3F27B8),
    gradientBottom: Color(0xFF241463),
    cardShadow: Color(0x00000000),
    textPrimary: Color(0xFFF2F2F7),
    textSecondary: Color(0xFFA3A3B2),
    textTertiary: Color(0xFF7E7E92),
    textFaint: Color(0xFF5E5E70),
    present: Color(0xFF3DD68C),
    absent: Color(0xFFE87C7C),
    cancelled: Color(0xFF8B8B9E),
    // A muted sand rather than alarm-orange: "tight" means pay attention, not
    // panic, and this colour fills a whole meter bar.
    warning: Color(0xFFFFCE85),
  );

  /// Light is not an inversion of dark. Elevation runs the other way — the
  /// canvas is the *tinted* layer and cards sit on white above it — and every
  /// accent and status colour is darkened until it carries its meaning against
  /// a white card rather than glowing on black.
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFF3F4FB),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFF3F4FB),
    surfaceHigher: Color(0xFFEDECF3),
    navSurface: Color(0xFFFFFFFF),
    outline: Color(0xFFDCDCE6),
    outlineSoft: Color(0xFFEDECF3),
    hairline: Color(0xFFE2E1EC),
    accent: Color(0xFF6C4CF0),
    accentSoft: Color(0xFFEDE8FE),
    cyan: Color(0xFF0E9B96),
    gradientTop: Color(0xFF7B5CFF),
    gradientMid: Color(0xFF5B3BE8),
    gradientBottom: Color(0xFF4B2FD6),
    cardShadow: Color(0x124C4696),
    textPrimary: Color(0xFF14141B),
    textSecondary: Color(0xFF5A5A6E),
    textTertiary: Color(0xFF8B8B9E),
    textFaint: Color(0xFFB4B4C4),
    present: Color(0xFF12A05F),
    absent: Color(0xFFC0504E),
    cancelled: Color(0xFF8B8B9E),
    // Bronze rather than a hot orange. On white a warning colour has to be
    // dark to stay legible, so the calm comes from dropping saturation
    // instead of lightening it.
    warning: Color(0xFFB57516),
  );

  /// Violet repeats what [dark] and [light] already hold, so the default
  /// tint is the one the app shipped with and nothing moves for anybody who
  /// never opens the picker.
  static const Map<AccentColour, _AccentSet> _darkAccents =
      <AccentColour, _AccentSet>{
    AccentColour.violet: _AccentSet(
      accent: Color(0xFFA28FFF),
      soft: Color(0xFF2A2542),
      top: Color(0xFF5B45E8),
      mid: Color(0xFF3F27B8),
      bottom: Color(0xFF241463),
    ),
    AccentColour.indigo: _AccentSet(
      accent: Color(0xFF8FB0FF),
      soft: Color(0xFF1E2740),
      top: Color(0xFF3D5BE8),
      mid: Color(0xFF2540B8),
      bottom: Color(0xFF142463),
    ),
    AccentColour.teal: _AccentSet(
      accent: Color(0xFF5FD8D2),
      soft: Color(0xFF14302F),
      top: Color(0xFF1B8F8B),
      mid: Color(0xFF12706E),
      bottom: Color(0xFF084543),
    ),
    AccentColour.magenta: _AccentSet(
      accent: Color(0xFFFF93D6),
      soft: Color(0xFF3A1E33),
      top: Color(0xFFD63C9E),
      mid: Color(0xFFA82778),
      bottom: Color(0xFF63144A),
    ),
    AccentColour.slate: _AccentSet(
      accent: Color(0xFFA9B6CC),
      soft: Color(0xFF232933),
      top: Color(0xFF4A5772),
      mid: Color(0xFF333D52),
      bottom: Color(0xFF1C2230),
    ),
  };

  static const Map<AccentColour, _AccentSet> _lightAccents =
      <AccentColour, _AccentSet>{
    AccentColour.violet: _AccentSet(
      accent: Color(0xFF6C4CF0),
      soft: Color(0xFFEDE8FE),
      top: Color(0xFF7B5CFF),
      mid: Color(0xFF5B3BE8),
      bottom: Color(0xFF4B2FD6),
      shadow: Color(0x124C4696),
    ),
    AccentColour.indigo: _AccentSet(
      accent: Color(0xFF2F55E0),
      soft: Color(0xFFE4EBFE),
      top: Color(0xFF5C86FF),
      mid: Color(0xFF3B5BE8),
      bottom: Color(0xFF2F49D6),
      shadow: Color(0x12324C96),
    ),
    AccentColour.teal: _AccentSet(
      accent: Color(0xFF0E8F8A),
      soft: Color(0xFFDFF4F3),
      top: Color(0xFF17B2AC),
      mid: Color(0xFF0E8F8A),
      bottom: Color(0xFF0A736F),
      shadow: Color(0x12147E7A),
    ),
    AccentColour.magenta: _AccentSet(
      accent: Color(0xFFC4267F),
      soft: Color(0xFFFDE6F3),
      top: Color(0xFFE8579F),
      mid: Color(0xFFC43B85),
      bottom: Color(0xFFA82A72),
      shadow: Color(0x12961B6B),
    ),
    AccentColour.slate: _AccentSet(
      accent: Color(0xFF4B5A72),
      soft: Color(0xFFE8ECF3),
      top: Color(0xFF6E7F9C),
      mid: Color(0xFF4F5E78),
      bottom: Color(0xFF3D4A60),
      shadow: Color(0x123E4A63),
    ),
  };

  /// A value class in every other respect, so equality is by value too. It
  /// also keeps `AppTheme.dark()` equal to [dark]: tinting rebuilds the
  /// palette, and without this an untinted theme stopped comparing equal to
  /// the constant it was built from.
  List<Object?> get _values => <Object?>[
        brightness, canvas, surface, surfaceHigh, surfaceHigher, navSurface,
        outline, outlineSoft, hairline, accent, accentSoft, cyan, gradientTop,
        gradientMid, gradientBottom, cardShadow, textPrimary, textSecondary,
        textTertiary, textFaint, present, absent, cancelled, warning,
      ];

  @override
  bool operator ==(Object other) =>
      other is AppPalette && listEquals(other._values, _values);

  @override
  int get hashCode => Object.hashAll(_values);

  /// The base palette tinted. Only the five identity colours move — surfaces,
  /// text and the status colours are the same whichever accent is chosen.
  AppPalette withAccent(AccentColour accent) {
    final _AccentSet set = (brightness == Brightness.dark
        ? _darkAccents
        : _lightAccents)[accent]!;
    return copyWith(
      accent: set.accent,
      accentSoft: set.soft,
      gradientTop: set.top,
      gradientMid: set.mid,
      gradientBottom: set.bottom,
      cardShadow: set.shadow,
    );
  }

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? canvas,
    Color? surface,
    Color? surfaceHigh,
    Color? surfaceHigher,
    Color? navSurface,
    Color? outline,
    Color? outlineSoft,
    Color? hairline,
    Color? accent,
    Color? accentSoft,
    Color? cyan,
    Color? gradientTop,
    Color? gradientMid,
    Color? gradientBottom,
    Color? cardShadow,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textFaint,
    Color? present,
    Color? absent,
    Color? cancelled,
    Color? warning,
  }) {
    return AppPalette(
      brightness: brightness ?? this.brightness,
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      surfaceHigher: surfaceHigher ?? this.surfaceHigher,
      navSurface: navSurface ?? this.navSurface,
      outline: outline ?? this.outline,
      outlineSoft: outlineSoft ?? this.outlineSoft,
      hairline: hairline ?? this.hairline,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      cyan: cyan ?? this.cyan,
      gradientTop: gradientTop ?? this.gradientTop,
      gradientMid: gradientMid ?? this.gradientMid,
      gradientBottom: gradientBottom ?? this.gradientBottom,
      cardShadow: cardShadow ?? this.cardShadow,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textFaint: textFaint ?? this.textFaint,
      present: present ?? this.present,
      absent: absent ?? this.absent,
      cancelled: cancelled ?? this.cancelled,
      warning: warning ?? this.warning,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      // Brightness cannot be interpolated, so it flips at the midpoint rather
      // than producing a nonsensical in-between value.
      brightness: t < 0.5 ? brightness : other.brightness,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      surfaceHigher: Color.lerp(surfaceHigher, other.surfaceHigher, t)!,
      navSurface: Color.lerp(navSurface, other.navSurface, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      outlineSoft: Color.lerp(outlineSoft, other.outlineSoft, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      cyan: Color.lerp(cyan, other.cyan, t)!,
      gradientTop: Color.lerp(gradientTop, other.gradientTop, t)!,
      gradientMid: Color.lerp(gradientMid, other.gradientMid, t)!,
      gradientBottom: Color.lerp(gradientBottom, other.gradientBottom, t)!,
      cardShadow: Color.lerp(cardShadow, other.cardShadow, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      present: Color.lerp(present, other.present, t)!,
      absent: Color.lerp(absent, other.absent, t)!,
      cancelled: Color.lerp(cancelled, other.cancelled, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}

extension AppPaletteContext on BuildContext {
  /// The palette for the current theme. Falls back to dark rather than
  /// throwing, so a widget pumped in a bare `MaterialApp` in a test still
  /// renders.
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;
}

/// Theme-independent design data.
class AppColors {
  const AppColors._();

  /// Palette offered when creating a subject.
  ///
  /// Stored as raw ARGB ints because that is exactly what goes into the
  /// database — it avoids any `Color.value` / `Color.toARGB32()` API churn
  /// between Flutter versions. Subject colours are the user's choice and are
  /// deliberately identical in both themes so a subject stays recognisable.
  static const List<int> subjectPalette = <int>[
    0xFF7C6BFF,
    0xFF4FD6D2,
    0xFFFF7A9A,
    0xFFFFB84D,
    0xFF3DD68C,
    0xFF6BA8FF,
    0xFFD68CFF,
    0xFFFF9066,
    0xFF9BE36D,
    0xFF5CCFFF,
  ];

  static const int defaultSubjectColor = 0xFF7C6BFF;

  /// WCAG relative-luminance contrast ratio between two opaque colours.
  static double contrast(Color a, Color b) {
    double channel(double c) => c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    double luminance(Color c) =>
        0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    final double la = luminance(a);
    final double lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// A subject's colour darkened or lightened until it reads as text on the
  /// current card surface. Subject colours are picked for identity on a tile
  /// — lime on white is about 1.5:1 — so the hue is kept and only the
  /// lightness is walked until the contrast clears AA.
  static Color inkOn(Color base, AppPalette palette) {
    final HSLColor hsl = HSLColor.fromColor(base);
    final double direction = palette.isDark ? 1 : -1;
    // Deep colours on white can need a saturation lift to stay recognisable
    // once darkened; on black the opposite is never a problem.
    final double saturation =
        palette.isDark ? hsl.saturation : math.min(1, hsl.saturation * 1.1);

    HSLColor candidate = hsl.withSaturation(saturation);
    for (int step = 0; step <= 50; step++) {
      final double lightness =
          (hsl.lightness + direction * step * 0.02).clamp(0.0, 1.0);
      candidate = candidate.withLightness(lightness);
      if (contrast(candidate.toColor(), palette.surface) >= 4.5) break;
      if (lightness == 0 || lightness == 1) break;
    }
    return candidate.toColor();
  }
}

/// The design was drawn on a 320dp phone artboard, so every size in it is a
/// phone size. A tablet is not a bigger phone held at the same distance — it
/// is held further away — so the whole scale steps up rather than each widget
/// guessing.
///
/// The ramp is continuous, not a breakpoint: a 7" foldable sits between a
/// phone and a tablet and should get a proportional amount, not fall off a
/// cliff at some width. Below [phoneWidth] the design is used exactly as
/// drawn, because at that size it already is the right size.
class AppScale {
  const AppScale._();

  /// At or under this, no scaling — this is what the design was drawn for.
  static const double phoneWidth = 600;

  /// Where the ramp tops out.
  static const double largeWidth = 900;

  static const double _maxFactor = 1.3;

  static double of(Size size) {
    final double width = size.shortestSide;
    if (width <= phoneWidth) return 1;
    final double t =
        ((width - phoneWidth) / (largeWidth - phoneWidth)).clamp(0.0, 1.0);
    return 1 + (_maxFactor - 1) * t;
  }

  /// The content column, which grows with the type or the lines get short and
  /// the page starts to look like a phone screenshot in a frame.
  static double contentWidth(Size size) => 560 * of(size);
}

/// Multiplies the viewer's own text scaling rather than replacing it, so a
/// larger system font still compounds on a tablet.
@immutable
class ScaledText extends TextScaler {
  const ScaledText(this.inner, this.factor);

  final TextScaler inner;
  final double factor;

  @override
  double scale(double fontSize) => inner.scale(fontSize * factor);

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => inner.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is ScaledText && other.inner == inner && other.factor == factor;

  @override
  int get hashCode => Object.hash(inner, factor);
}

/// The two bundled families. Referenced by name rather than by a `TextStyle`
/// constant so a caller can set a size and weight without inheriting one.
class AppFonts {
  const AppFonts._();

  static const String sans = 'Plus Jakarta Sans';

  /// Times, dates, room codes and counts. A tabular figure keeps a column of
  /// start times aligned, which the proportional face does not.
  static const String mono = 'JetBrains Mono';
}

/// Shared spacing / radius scale so layouts stay rhythmically consistent.
class AppSpacing {
  const AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 20;
  static const double radiusXl = 28;

  /// The radius of the sheet that lifts over a gradient header.
  static const double radiusSheet = 28;
}

class AppTheme {
  const AppTheme._();

  /// System bars follow the palette, so the status bar icons stay legible when
  /// the theme flips.
  static SystemUiOverlayStyle overlayStyleFor(AppPalette p) {
    final Brightness icons = p.isDark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: p.brightness,
      systemNavigationBarColor: p.navSurface,
      systemNavigationBarIconBrightness: icons,
    );
  }

  /// The variant used while a gradient header is behind the status bar.
  static SystemUiOverlayStyle overlayStyleOnGradient(AppPalette p) {
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: p.navSurface,
      systemNavigationBarIconBrightness:
          p.isDark ? Brightness.light : Brightness.dark,
    );
  }

  static ThemeData dark([AccentColour accent = AccentColour.violet]) =>
      _build(AppPalette.dark.withAccent(accent));

  static ThemeData light([AccentColour accent = AccentColour.violet]) =>
      _build(AppPalette.light.withAccent(accent));

  /// One builder for both themes. Everything below reads from [p], so a colour
  /// can never be right in one theme and hard-coded wrong in the other.
  static ThemeData _build(AppPalette p) {
    final bool isDark = p.isDark;

    final ColorScheme scheme = ColorScheme(
      brightness: p.brightness,
      primary: p.accent,
      onPrimary: isDark ? const Color(0xFF1B1040) : Colors.white,
      primaryContainer: p.accentSoft,
      onPrimaryContainer: isDark ? p.textPrimary : p.accent,
      secondary: p.cyan,
      onSecondary: isDark ? const Color(0xFF04302F) : Colors.white,
      secondaryContainer:
          isDark ? const Color(0xFF16403F) : const Color(0xFFD7F3F1),
      onSecondaryContainer: isDark ? p.textPrimary : const Color(0xFF06403D),
      error: p.absent,
      onError: Colors.white,
      errorContainer:
          isDark ? const Color(0xFF4A1F22) : const Color(0xFFFBE0E0),
      onErrorContainer: isDark ? p.textPrimary : const Color(0xFF5C1616),
      surface: p.surface,
      onSurface: p.textPrimary,
      onSurfaceVariant: p.textSecondary,
      surfaceContainerLowest: p.canvas,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surfaceHigh,
      surfaceContainerHigh: p.surfaceHigher,
      surfaceContainerHighest: p.surfaceHigher,
      outline: p.outline,
      outlineVariant: p.outlineSoft,
      inverseSurface: p.textPrimary,
      onInverseSurface: p.canvas,
      inversePrimary: p.accentSoft,
      shadow: Colors.black,
      scrim: Colors.black,
    );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
      fontFamily: AppFonts.sans,
      scaffoldBackgroundColor: p.canvas,
      canvasColor: p.canvas,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      extensions: <ThemeExtension<dynamic>>[p],
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme, p),
      // Flutter 3.35 normalised component themes: ThemeData now takes the
      // *ThemeData variants of these two.
      appBarTheme: AppBarThemeData(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: overlayStyleOnGradient(p),
        titleTextStyle: const TextStyle(
          fontFamily: AppFonts.sans,
          color: Colors.white,
          fontSize: 19,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: p.outlineSoft,
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.navSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        elevation: 0,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((states) {
          final bool selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 23,
            color: selected ? p.accent : p.textFaint,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
          final bool selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: AppFonts.sans,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? p.accent : p.textFaint,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        // Not surfaceHigh: in the light palette that is the same colour as the
        // canvas a sheet is painted with, so the field would vanish into it.
        fillColor: p.surfaceHigher,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        hintStyle: TextStyle(color: p.textTertiary),
        labelStyle: TextStyle(color: p.textSecondary),
        // A field keeps a hairline even below the sheet edge: an empty one
        // with neither outline nor contrast reads as a caption, not as
        // somewhere to type. The focus ring is still the accent.
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          borderSide: BorderSide(color: p.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          borderSide: BorderSide(color: p.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          borderSide: BorderSide(color: p.accent, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          borderSide: BorderSide(color: p.absent),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          borderSide: BorderSide(color: p.absent, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: isDark ? const Color(0xFF1B1040) : Colors.white,
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          textStyle: const TextStyle(
            fontFamily: AppFonts.sans,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accent,
          textStyle: const TextStyle(
            fontFamily: AppFonts.sans,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.textPrimary,
          // Same trap as the field fill: surfaceHigh is the sheet's own colour
          // in light. A secondary button carries a fill *and* a hairline —
          // without either it reads as a line of text rather than a control.
          backgroundColor: p.surfaceHigher,
          minimumSize: const Size(0, 52),
          side: BorderSide(color: p.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          textStyle: const TextStyle(
            fontFamily: AppFonts.sans,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        // The FAB paints its own gradient, so the theme only has to stop
        // Material from painting a flat fill and a shadow underneath it.
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.canvas,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: p.canvas,
        showDragHandle: true,
        dragHandleColor: p.textFaint,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSpacing.radiusSheet),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        // Dark keeps a raised surface; light needs a dark chip or the snackbar
        // vanishes into the page.
        backgroundColor: isDark ? p.surfaceHigher : const Color(0xFF23232E),
        contentTextStyle: TextStyle(
          fontFamily: AppFonts.sans,
          color: isDark ? p.textPrimary : Colors.white,
        ),
        // The chip is dark in both themes, so Undo takes the light violet even
        // in light — the light palette's accent is far too dark against it.
        actionTextColor: isDark ? p.accent : const Color(0xFFA28FFF),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        ),
      ),
      // A range's in-between band defaults to secondaryContainer, so the two
      // ends come out violet and everything between them mint.
      datePickerTheme: DatePickerThemeData(
        backgroundColor: p.surface,
        rangeSelectionBackgroundColor: p.accentSoft,
      ),
      // The picker opens on its keyboard, so the hour and minute are fields
      // and have to look like fields: on a white dialog the Material default
      // fill is a shade the eye cannot find, which leaves two bare numbers and
      // their labels floating. The day period is the app's violet rather than
      // the scheme's tertiary, which lands on teal here.
      timePickerTheme: TimePickerThemeData(
        backgroundColor: p.surface,
        hourMinuteColor: WidgetStateColor.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? p.accentSoft
              : p.surfaceHigher,
        ),
        hourMinuteTextColor: WidgetStateColor.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? p.accent
              : p.textPrimary,
        ),
        hourMinuteShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          side: BorderSide(color: p.outline),
        ),
        // The display styles carry tight negative tracking, which throws the
        // two numbers off centre inside their boxes.
        hourMinuteTextStyle: const TextStyle(
          fontFamily: AppFonts.sans,
          fontSize: 40,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        dayPeriodColor: WidgetStateColor.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? p.accentSoft
              : Colors.transparent,
        ),
        dayPeriodTextColor: WidgetStateColor.resolveWith(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? p.accent
              : p.textSecondary,
        ),
        dayPeriodBorderSide: BorderSide(color: p.outline),
        dayPeriodShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          side: BorderSide(color: p.outline),
        ),
        dialHandColor: p.accent,
        dialBackgroundColor: p.surfaceHigher,
        helpTextStyle: TextStyle(
          fontFamily: AppFonts.sans,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: p.textSecondary,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return isDark ? p.textTertiary : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color>((states) {
          return states.contains(WidgetState.selected)
              ? p.accent
              : p.surfaceHigher;
        }),
        trackOutlineColor: WidgetStateProperty.all<Color>(Colors.transparent),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.textSecondary,
        textColor: p.textPrimary,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceHigh,
        side: BorderSide.none,
        labelStyle: TextStyle(
          fontFamily: AppFonts.sans,
          color: p.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.accent,
        inactiveTrackColor: p.surfaceHigher,
        thumbColor: p.accent,
        overlayColor: p.accent.withValues(alpha: 0.12),
        trackHeight: 4,
        // The default 24px overlay indents the track that far from its own
        // padding, which left every slider sitting right of the cards above
        // and below it.
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.surfaceHigher,
        circularTrackColor: p.surfaceHigher,
      ),
    );
  }

  static TextTheme _textTheme(TextTheme base, AppPalette p) {
    return base
        .copyWith(
          displaySmall: base.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -1.6,
          ),
          headlineMedium: base.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
          headlineSmall: base.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.7,
          ),
          titleLarge: base.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
          titleMedium: base.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
          bodyMedium: base.bodyMedium?.copyWith(height: 1.35),
          labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        )
        .apply(bodyColor: p.textPrimary, displayColor: p.textPrimary);
  }
}
