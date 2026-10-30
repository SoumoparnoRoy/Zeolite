import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_theme.dart';

const List<DeviceOrientation> _portrait = <DeviceOrientation>[
  DeviceOrientation.portraitUp,
  DeviceOrientation.portraitDown,
];

/// Phones stay portrait; a display at least [AppScale.phoneWidth] on its short
/// side turns with the device. The same breakpoint as the type scale, so
/// "this is a phone" means one thing.
List<DeviceOrientation> orientationsFor(double shortestSideDp) =>
    shortestSideDp < AppScale.phoneWidth ? _portrait : DeviceOrientation.values;

/// Applies [orientationsFor] at launch and again when the display changes
/// under the app, which is a foldable opening or closing.
///
/// Measured on the display, not the window: split screen can shrink a
/// tablet's window under 600dp, and locking it back to portrait mid-use would
/// be worse than the stretched layout. A display's short side does not change
/// on rotation either, so the answer cannot flip back and forth.
class OrientationPolicy with WidgetsBindingObserver {
  bool? _wide;

  Future<void> apply() async {
    final FlutterView? view =
        WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    final Display display = view.display;
    final double shortest =
        (display.size / display.devicePixelRatio).shortestSide;
    final bool wide = shortest >= AppScale.phoneWidth;
    // didChangeMetrics also fires on every rotation and keyboard, and
    // re-sending the same list each time is a platform call for nothing.
    if (wide == _wide) return;
    _wide = wide;
    await SystemChrome.setPreferredOrientations(orientationsFor(shortest));
  }

  @override
  void didChangeMetrics() => unawaited(apply());
}
