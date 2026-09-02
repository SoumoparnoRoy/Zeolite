import 'package:flutter/services.dart';

/// A launcher icon the user can pick.
///
/// [wire] is the activity-alias the manifest declares and the launcher records,
/// so these strings are fixed once shipped — renaming one orphans anybody's
/// pinned shortcut.
enum LauncherIcon {
  standard('default', 'Default'),
  teal('teal', 'Teal'),
  sky('sky', 'Sky'),
  indigo('indigo', 'Indigo'),
  violet('violet', 'Violet'),
  plum('plum', 'Plum'),
  magenta('magenta', 'Magenta'),
  slate('slate', 'Slate');

  const LauncherIcon(this.wire, this.label);

  final String wire;
  final String label;

  String get preview => 'assets/icon/launcher/$wire.png';

  static LauncherIcon fromWire(String? value) {
    for (final LauncherIcon icon in LauncherIcon.values) {
      if (icon.wire == value) return icon;
    }
    return LauncherIcon.standard;
  }
}

/// Which icon the launcher shows for the app.
///
/// Android holds this, not the app: the enabled alias lives in `PackageManager`
/// and survives an update, so a copy in settings could only ever drift from
/// what is actually on the home screen.
class LauncherIconService {
  const LauncherIconService();

  static const MethodChannel _channel =
      MethodChannel('zeolite/launcher_icon');

  /// The default on any platform that has no aliases — which is every one but
  /// Android, and the test host.
  Future<LauncherIcon> current() async {
    try {
      return LauncherIcon.fromWire(
        await _channel.invokeMethod<String>('current'),
      );
    } on PlatformException {
      return LauncherIcon.standard;
    } on MissingPluginException {
      return LauncherIcon.standard;
    }
  }

  Future<void> select(LauncherIcon icon) => _channel.invokeMethod<void>(
        'select',
        <String, Object?>{'icon': icon.wire},
      );
}
