import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_theme.dart';
import 'launch_geometry.dart';
import 'launch_painter.dart';

/// What the welcome screen was asked.
enum WelcomeChoice { create, signIn, continueWithout }

/// The welcome screen's copy: everything below the crystal.
///
/// Real widgets rather than more painting, because these are the things that
/// have to be tappable, readable by a screen reader and able to grow with the
/// text scaler. The heading above them stays painted — it is the wordmark
/// still arriving, not a second heading.
class WelcomeCopy extends StatefulWidget {
  const WelcomeCopy({
    super.key,
    required this.metrics,
    required this.colors,
    required this.progress,
    required this.onChoice,
  });

  static const String heading = 'Welcome to Zeolite';
  static const String termsIntro = 'By continuing, you agree to our';
  static const String termsName = 'Terms of Use';
  static const String privacyName = 'Privacy Policy';
  static const String createLabel = 'Create a new account';
  static const String signInLabel = 'Already have an account';
  static const String continueLabel = 'Continue without an account';

  /// Without this, "Continue without an account" reads as a limited trial
  /// rather than as the whole app.
  static const String caption = 'Everything works offline. Sync is optional.';

  static final Uri termsUrl = Uri.parse('https://zeolite-app.web.app/terms');
  static final Uri privacyUrl =
      Uri.parse('https://zeolite-app.web.app/privacy');

  final WelcomeMetrics metrics;
  final LaunchColors colors;

  /// The hand-off's own progress, 0 to 1.
  final double progress;

  final ValueChanged<WelcomeChoice> onChoice;

  @override
  State<WelcomeCopy> createState() => _WelcomeCopyState();
}

class _WelcomeCopyState extends State<WelcomeCopy> {
  late final TapGestureRecognizer _terms = _open(WelcomeCopy.termsUrl);
  late final TapGestureRecognizer _privacy = _open(WelcomeCopy.privacyUrl);

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  TapGestureRecognizer _open(Uri url) => TapGestureRecognizer()
    ..onTap = () => launchUrl(url, mode: LaunchMode.inAppBrowserView);

  WelcomeMetrics get metrics => widget.metrics;
  LaunchColors get colors => widget.colors;

  @override
  Widget build(BuildContext context) {
    final double copy = seg(widget.progress, 0.55, 0.9);
    final double buttons = seg(widget.progress, 0.6, 1);
    // Positioned even when there is nothing to show yet — see the Stack in
    // `launch_screen.dart`.
    if (copy <= 0 && buttons <= 0) {
      return const Positioned(
          left: 0, bottom: 0, width: 0, height: 0, child: SizedBox.shrink());
    }

    final double scale = metrics.scale;
    final double rise = lerpd(22, 0, easeOut(buttons));

    // Anchored to the bottom and sized by its content rather than to
    // `stackHeight`, which is only an estimate: a long enough label or a large
    // enough text scale would overflow a fixed box, and the heading drifting a
    // few pixels closer is a far better failure than a clipped button.
    return Positioned(
      left: 0,
      right: 0,
      bottom: WelcomeMetrics.bottomMargin + metrics.bottomInset - rise,
      child: Center(
        child: SizedBox(
          width: metrics.copyWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Opacity(opacity: copy, child: _termsLines(scale)),
              SizedBox(height: WelcomeMetrics.termsGap * scale),
              Opacity(
                opacity: buttons,
                child: Column(
                  children: <Widget>[
                    _button(
                      label: WelcomeCopy.createLabel,
                      background: colors.accent,
                      foreground: colors.canvas,
                      weight: FontWeight.w700,
                      onTap: () => widget.onChoice(WelcomeChoice.create),
                    ),
                    SizedBox(height: WelcomeMetrics.buttonGap * scale),
                    _button(
                      label: WelcomeCopy.signInLabel,
                      background: colors.surfaceHigh,
                      foreground: colors.text,
                      weight: FontWeight.w600,
                      onTap: () => widget.onChoice(WelcomeChoice.signIn),
                    ),
                    SizedBox(height: WelcomeMetrics.buttonGap * scale),
                    _button(
                      label: WelcomeCopy.continueLabel,
                      background: Colors.transparent,
                      foreground: colors.textSecondary,
                      weight: FontWeight.w500,
                      onTap: () =>
                          widget.onChoice(WelcomeChoice.continueWithout),
                    ),
                    SizedBox(height: WelcomeMetrics.captionGap * scale),
                    Text(
                      WelcomeCopy.caption,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: AppFonts.sans,
                        fontWeight: FontWeight.w500,
                        fontSize: 11.5 * scale,
                        color: colors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button({
    required String label,
    required Color background,
    required Color foreground,
    required FontWeight weight,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WelcomeMetrics.buttonInset,
      ),
      child: SizedBox(
        height: metrics.buttonH,
        width: double.infinity,
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(WelcomeMetrics.buttonRadius),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(WelcomeMetrics.buttonRadius),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: AppFonts.sans,
                  fontWeight: weight,
                  fontSize: 15 * metrics.scale,
                  color: foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Named for the documents the site actually publishes: it has a Privacy
  /// Policy and Terms of Use, so neither link can say Terms of Service.
  Widget _termsLines(double scale) {
    final TextStyle base = TextStyle(
      fontFamily: AppFonts.sans,
      fontWeight: FontWeight.w500,
      fontSize: 12 * scale,
      height: WelcomeMetrics.termsLine / 12,
      color: colors.textTertiary,
    );
    final TextStyle link = base.copyWith(
      color: colors.accent,
      decoration: TextDecoration.underline,
      decorationColor: colors.accent,
    );

    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(text: '${WelcomeCopy.termsIntro}\n', style: base),
          TextSpan(
            text: WelcomeCopy.termsName,
            style: link,
            recognizer: _terms,
          ),
          TextSpan(text: ' and ', style: base),
          TextSpan(
            text: WelcomeCopy.privacyName,
            style: link,
            recognizer: _privacy,
          ),
          TextSpan(text: '.', style: base),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
