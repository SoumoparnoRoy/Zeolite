/// Every address the app reaches, in one place.
///
/// The server can be swapped at build time
/// (`--dart-define=ZEOLITE_SERVER=http://10.0.2.2:8080`) so a debug build can
/// talk to a local or staging copy without touching the code.
abstract final class Endpoints {
  static const String server = String.fromEnvironment(
    'ZEOLITE_SERVER',
    defaultValue: 'https://zeolite.onrender.com',
  );

  static final Uri terms = Uri.parse('https://zeolite-app.web.app/terms');
  static final Uri privacy = Uri.parse('https://zeolite-app.web.app/privacy');

  /// Opened by the update screen. Android hands it to the Play Store app.
  static final Uri playStore = Uri.parse(
    'https://play.google.com/store/apps/details?id=com.soumoparno.zeolite',
  );
}
