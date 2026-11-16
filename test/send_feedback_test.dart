import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/endpoints.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/settings/settings_pages.dart';
import 'package:zeolite/services/feedback_mail.dart';
import 'package:zeolite/state/providers.dart';

class _Stored extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

const MethodChannel _urls = MethodChannel('plugins.flutter.io/url_launcher');
const MethodChannel _device = MethodChannel('zeolite/device');

Widget _row() => ProviderScope(
      overrides: [
        settingsProvider.overrideWith(_Stored.new),
        timetableProvider.overrideWith((Ref ref) async => const TimetableData(
              categories: [],
              subjects: [],
              slots: [],
              extras: [],
              holidays: [],
              records: [],
            )),
        appVersionProvider.overrideWith((Ref ref) async => '1.0.1'),
        appBuildProvider.overrideWith((Ref ref) async => 6),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ListView(
            children: const <Widget>[SettingsItemRow(SettingsItem.feedback)],
          ),
        ),
      ),
    );

void main() {
  late List<String> launched;
  late bool hasEmailApp;
  late bool launchThrows;
  late List<Object?> clipboard;

  setUp(() {
    launched = <String>[];
    hasEmailApp = true;
    launchThrows = false;
    clipboard = <Object?>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_urls, (MethodCall call) async {
      launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
      // What url_launcher_android does when no app takes the intent.
      if (launchThrows) throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
      return hasEmailApp;
    });
    messenger.setMockMethodCallHandler(
      _device,
      (MethodCall call) async => '16 (API 36)',
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map<Object?, Object?>)['text']);
      }
      return null;
    });
  });

  test('the draft keeps spaces and line breaks readable', () {
    final Uri draft = FeedbackMail.draft(app: '1.0.1 (6)', android: '16');
    expect(draft.scheme, 'mailto');
    expect(draft.path, Endpoints.support);
    expect(draft.query, isNot(contains('+')));
    expect(draft.queryParameters['subject'], 'Zeolite feedback');
    expect(draft.queryParameters['body'],
        '\n\n\n---\nZeolite 1.0.1 (6)\nAndroid 16');
  });

  test('without an Android version the line is left out', () {
    expect(
      FeedbackMail.draft(app: '1.0.1 (6)').queryParameters['body'],
      isNot(contains('Android')),
    );
  });

  testWidgets('the row reads as one enabled button with its name and line',
      (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('Send feedback')),
      matchesSemantics(
        label: 'Send feedback\nEmail the developer',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('a tap opens a draft with both versions filled in',
      (WidgetTester tester) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();

    final Uri draft = Uri.parse(launched.single);
    expect(draft.path, Endpoints.support);
    expect(draft.queryParameters['body'],
        allOf(contains('Zeolite 1.0.1 (6)'), contains('Android 16 (API 36)')));
    expect(find.text('No email app found'), findsNothing);
  });

  testWidgets('with no email app, the address is shown and can be copied',
      (WidgetTester tester) async {
    hasEmailApp = false;
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();

    expect(find.text('No email app found'), findsOneWidget);
    expect(find.textContaining(Endpoints.support), findsOneWidget);

    await tester.tap(find.text('Copy address'));
    await tester.pumpAndSettle();

    expect(clipboard, <Object?>[Endpoints.support]);
    expect(find.text('No email app found'), findsNothing);
    expect(find.text('Address copied'), findsOneWidget);
  });

  testWidgets('a launcher that throws gets the same address dialog',
      (WidgetTester tester) async {
    launchThrows = true;
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('No email app found'), findsOneWidget);
  });
}
