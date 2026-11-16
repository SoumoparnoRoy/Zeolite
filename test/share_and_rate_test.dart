import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/endpoints.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/settings/settings_pages.dart';
import 'package:zeolite/state/providers.dart';

class _Stored extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

const MethodChannel _share = MethodChannel('dev.fluttercommunity.plus/share');
const MethodChannel _urls = MethodChannel('plugins.flutter.io/url_launcher');

Widget _rows() => ProviderScope(
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
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ListView(
            children: const <Widget>[
              SettingsItemRow(SettingsItem.share),
              SettingsItemRow(SettingsItem.rate),
            ],
          ),
        ),
      ),
    );

void main() {
  late List<MethodCall> shared;
  late List<MethodCall> opened;

  setUp(() {
    shared = <MethodCall>[];
    opened = <MethodCall>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_share, (MethodCall call) async {
      shared.add(call);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    messenger.setMockMethodCallHandler(_urls, (MethodCall call) async {
      opened.add(call);
      return true;
    });
  });

  testWidgets('each row reads as one enabled button with its name and line',
      (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(_rows());
    await tester.pumpAndSettle();

    for (final (String name, String line) in <(String, String)>[
      ('Share Zeolite', 'Send a friend the link'),
      ('Rate Zeolite', 'Leave a rating on Google Play'),
    ]) {
      expect(
        tester.getSemantics(find.text(name)),
        matchesSemantics(
          label: '$name\n$line',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
        ),
        reason: name,
      );
    }
    semantics.dispose();
  });

  testWidgets('Share hands the message and the Play link to the share sheet',
      (WidgetTester tester) async {
    await tester.pumpWidget(_rows());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Share Zeolite'));
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    final Map<Object?, Object?> args =
        shared.single.arguments as Map<Object?, Object?>;
    expect(args['text'], SettingsItem.shareMessage);
    expect(args['text'] as String, contains(Endpoints.playStore.toString()));
    expect(opened, isEmpty);
  });

  testWidgets('Rate opens the Play listing outside the app',
      (WidgetTester tester) async {
    await tester.pumpWidget(_rows());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rate Zeolite'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    final Map<Object?, Object?> args =
        opened.single.arguments as Map<Object?, Object?>;
    expect(args['url'], Endpoints.playStore.toString());
    expect(shared, isEmpty);
  });
}
