import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/launch/first_run_choices_screen.dart';
import 'package:zeolite/features/launch/launch_painter.dart';
import 'package:zeolite/features/launch/welcome_screen.dart';
import 'package:zeolite/features/settings/privacy_section.dart';
import 'package:zeolite/features/settings/settings_pages.dart';
import 'package:zeolite/features/timetable/import_screen.dart';
import 'package:zeolite/services/collection_switches.dart';
import 'package:zeolite/services/firebase/app_check_starter.dart';
import 'package:zeolite/state/auth_providers.dart';
import 'package:zeolite/state/privacy_providers.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/state/sync_providers.dart';
import 'package:zeolite/widgets/common.dart';

import 'fake_notifications.dart';

class _RecordingSwitches implements CollectionSwitches {
  final List<(bool, bool)> applied = <(bool, bool)>[];

  @override
  Future<void> apply({required bool usage, required bool crashes}) async =>
      applied.add((usage, crashes));
}

class _CountingAppCheck implements AppCheckStarter {
  int activations = 0;

  @override
  Future<void> activate() async => activations++;
}

class _Stored extends SettingsController {
  _Stored(this.initial);

  final AppSettings initial;

  @override
  Future<AppSettings> build() async => initial;
}

class _SignedInAs implements User {
  _SignedInAs(this.uid);

  @override
  final String uid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Verified extends VerificationPending {
  @override
  bool build() => false;
}

/// The real store underneath, so a saved answer is one that survives a
/// restart rather than one that only reached the provider.
Widget _app(Widget home, _RecordingSwitches switches,
    {AppSettings? settings, _CountingAppCheck? appCheck}) {
  return ProviderScope(
    overrides: [
      appCheckStarterProvider
          .overrideWithValue(appCheck ?? _CountingAppCheck()),
      if (settings != null)
        settingsProvider.overrideWith(() => _Stored(settings)),
      collectionSwitchesProvider.overrideWithValue(switches),
      notificationsProvider.overrideWithValue(QuietNotifications()),
      signedInUserProvider.overrideWith((Ref ref) => Stream<User?>.value(null)),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          ref.watch(collectionChoicesProvider);
          ref.watch(appCheckProvider);
          return home;
        },
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('the stored answers', () {
    test('start unanswered, and only an adult can be measured', () {
      const AppSettings fresh = AppSettings();
      expect(fresh.needsPrivacyChoices, isTrue);
      expect(fresh.usageAllowed, isFalse);

      const AppSettings minor =
          AppSettings(adult: false, shareUsage: true, sendCrashReports: true);
      expect(minor.needsPrivacyChoices, isFalse);
      expect(minor.usageAllowed, isFalse);
      expect(minor.crashReportsAllowed, isFalse);

      const AppSettings halfway = AppSettings(adult: true);
      expect(halfway.needsPrivacyChoices, isTrue);
    });

    test('survive a restart, and an unanswered one reads back unanswered',
        () async {
      final SettingsService service = SettingsService();
      await service.save(const AppSettings(adult: true, shareUsage: false));
      final AppSettings back = await service.load();
      expect(back.adult, isTrue);
      expect(back.shareUsage, isFalse);
      expect(back.sendCrashReports, isNull);
    });

    test('stay with the device: a backup neither carries nor overwrites them',
        () {
      const AppSettings here =
          AppSettings(adult: false, shareUsage: true, sendCrashReports: false);
      final Map<String, Object?> json =
          const AppSettings(adult: true, shareUsage: true).toJson();
      expect(json.keys, isNot(contains('adult')));
      expect(json.keys, isNot(contains('shareUsage')));

      final AppSettings restored = AppSettings.fromJson(json).onDeviceOf(here);
      expect(restored.adult, isFalse);
      expect(restored.sendCrashReports, isFalse);
    });
  });

  group('the first run', () {
    testWidgets('asks the age first', (WidgetTester tester) async {
      final _RecordingSwitches switches = _RecordingSwitches();
      await tester.pumpWidget(
          _app(const FirstRunChoicesScreen(settings: AppSettings()), switches));
      await tester.pumpAndSettle();

      expect(find.text(FirstRunChoicesScreen.ageQuestion), findsOneWidget);
      expect(find.text(FirstRunChoicesScreen.usageTitle), findsNothing);
      // Nothing is switched on while the question is open.
      expect(switches.applied, everyElement((false, false)));
    });

    testWidgets('a yes leads to both choices, neither picked yet',
        (WidgetTester tester) async {
      final _RecordingSwitches switches = _RecordingSwitches();
      await tester.pumpWidget(
          _app(const FirstRunChoicesScreen(settings: AppSettings()), switches));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();

      expect(find.text(FirstRunChoicesScreen.usageTitle), findsOneWidget);
      expect(find.text(FirstRunChoicesScreen.crashesTitle), findsOneWidget);
      // Each side is a button that says what it is, for TalkBack and for
      // the Maestro flow that taps them by text.
      final SemanticsHandle semantics = tester.ensureSemantics();
      for (final SemanticsNode node
          in find.semantics.byLabel('No').evaluate()) {
        expect(node.flagsCollection.isButton, isTrue);
      }
      semantics.dispose();
      for (final SegmentedButton<bool> choice
          in tester.widgetList<SegmentedButton<bool>>(
              find.byType(SegmentedButton<bool>))) {
        expect(choice.selected, isEmpty);
      }
      final FilledButton next =
          tester.widget(find.widgetWithText(FilledButton, 'Continue'));
      expect(next.onPressed, isNull, reason: 'nothing answered yet');
    });

    testWidgets('each answer is saved and handed to the SDKs separately',
        (WidgetTester tester) async {
      final _RecordingSwitches switches = _RecordingSwitches();
      await SettingsService().save(const AppSettings(adult: true));
      await tester.pumpWidget(_app(
          const FirstRunChoicesScreen(settings: AppSettings(adult: true)),
          switches));
      await tester.pumpAndSettle();

      // Yes to usage, no to crash reports.
      await tester.tap(find.text('Yes').first);
      await tester.pump();
      final FilledButton halfway =
          tester.widget(find.widgetWithText(FilledButton, 'Continue'));
      expect(halfway.onPressed, isNull, reason: 'one choice still open');
      await tester.tap(find.text('No').last);
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      final AppSettings stored = await SettingsService().load();
      expect(stored.shareUsage, isTrue);
      expect(stored.sendCrashReports, isFalse);
      expect(switches.applied.last, (true, false));
    });

    testWidgets('a no keeps everything off and asks nothing more',
        (WidgetTester tester) async {
      final _RecordingSwitches switches = _RecordingSwitches();
      await tester.pumpWidget(
          _app(const FirstRunChoicesScreen(settings: AppSettings()), switches));
      await tester.pumpAndSettle();

      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();

      final AppSettings stored = await SettingsService().load();
      expect(stored.adult, isFalse);
      expect(stored.needsPrivacyChoices, isFalse);
      expect(switches.applied.last, (false, false));
    });
  });

  group('App Check', () {
    Future<(ProviderContainer, _CountingAppCheck)> started() async {
      final _CountingAppCheck appCheck = _CountingAppCheck();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          appCheckStarterProvider.overrideWithValue(appCheck),
          collectionSwitchesProvider.overrideWithValue(_RecordingSwitches()),
        ],
      );
      addTearDown(container.dispose);
      container.listen(appCheckProvider, (_, __) {});
      await container.read(settingsProvider.future);
      await Future<void>.delayed(Duration.zero);
      return (container, appCheck);
    }

    test('waits while the age question is unanswered, and stays off on a no',
        () async {
      final (ProviderContainer container, _CountingAppCheck appCheck) =
          await started();
      expect(appCheck.activations, 0);

      await container.read(privacyChoicesProvider).setAdult(false);
      await Future<void>.delayed(Duration.zero);
      expect(appCheck.activations, 0);
    });

    test('starts on a yes, from Settings too, and only once', () async {
      final (ProviderContainer container, _CountingAppCheck appCheck) =
          await started();
      await container.read(privacyChoicesProvider).setAdult(false);
      await container
          .read(privacyChoicesProvider)
          .setAdult(true, fromSettings: true);
      await Future<void>.delayed(Duration.zero);
      expect(appCheck.activations, 1);
    });

    test('starts at launch for an install that already said yes', () async {
      await SettingsService().save(const AppSettings(adult: true));
      final (_, _CountingAppCheck appCheck) = await started();
      expect(appCheck.activations, 1);
    });

    testWidgets('starts when the first-run question gets a yes',
        (WidgetTester tester) async {
      final _CountingAppCheck appCheck = _CountingAppCheck();
      await tester.pumpWidget(_app(
        const FirstRunChoicesScreen(settings: AppSettings()),
        _RecordingSwitches(),
        appCheck: appCheck,
      ));
      await tester.pumpAndSettle();
      expect(appCheck.activations, 0);

      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(appCheck.activations, 1);
    });

    test('the account is not even listened to before a yes', () async {
      bool built = false;
      final ProviderContainer container = ProviderContainer(
        overrides: [
          authServiceProvider.overrideWith((Ref ref) {
            built = true;
            throw StateError('Firebase must not be reached');
          }),
        ],
      );
      addTearDown(container.dispose);
      container.listen(signedInUserProvider, (_, __) {});
      await container.read(settingsProvider.future);

      expect(await container.read(signedInUserProvider.future), isNull);
      expect(container.read(syncTargetProvider), isNull);
      expect(built, isFalse);
    });
  });

  group('under 18', () {
    const AppSettings minor = AppSettings(adult: false, onboarded: true);

    testWidgets('the collection switches are not there to flip',
        (WidgetTester tester) async {
      await tester.pumpWidget(_app(
        const Scaffold(body: SingleChildScrollView(child: PrivacySection())),
        _RecordingSwitches(),
        settings: minor,
      ));
      await tester.pumpAndSettle();

      expect(find.text('18 or older'), findsOneWidget);
      expect(find.text(FirstRunChoicesScreen.usageTitle), findsNothing);
      expect(find.text(FirstRunChoicesScreen.crashesTitle), findsNothing);
    });

    testWidgets('an adult sees both, off until turned on',
        (WidgetTester tester) async {
      await tester.pumpWidget(_app(
        const Scaffold(body: SingleChildScrollView(child: PrivacySection())),
        _RecordingSwitches(),
        settings: const AppSettings(
            adult: true, shareUsage: false, sendCrashReports: false),
      ));
      await tester.pumpAndSettle();

      expect(find.text(FirstRunChoicesScreen.usageTitle), findsOneWidget);
      expect(find.text(FirstRunChoicesScreen.crashesTitle), findsOneWidget);
    });

    testWidgets('Account and Notion say why they do nothing',
        (WidgetTester tester) async {
      await tester.pumpWidget(_app(
        Scaffold(
          body: ListView(
            children: const <Widget>[
              SettingsItemRow(SettingsItem.account),
              SettingsItemRow(SettingsItem.notion),
            ],
          ),
        ),
        _RecordingSwitches(),
        settings: minor,
      ));
      await tester.pumpAndSettle();

      expect(find.text(availableFrom18), findsNWidgets(2));
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsItemRow), findsNWidgets(2),
          reason: 'nothing opened');
      for (final AppRow row in tester.widgetList<AppRow>(find.byType(AppRow))) {
        expect(row.enabled, isFalse);
      }
    });

    testWidgets('the welcome screen offers no account',
        (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final List<WelcomeChoice> chosen = <WelcomeChoice>[];
      const Size size = Size(400, 860);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Stack(children: <Widget>[
            WelcomeCopy(
              metrics: WelcomeMetrics(
                size: size,
                scale: 1,
                frame: WelcomeMetrics.frameFor(size),
                bottomInset: 0,
              ),
              colors: LaunchColors.of(AccentColour.violet, Brightness.dark),
              progress: 1,
              onChoice: chosen.add,
              onDeviceOnly: true,
            ),
          ]),
        ),
      ));

      await tester.tap(find.text(WelcomeCopy.createLabel));
      await tester.tap(find.text(WelcomeCopy.signInLabel));
      await tester.tap(find.text(WelcomeCopy.continueLabel));
      expect(chosen, <WelcomeChoice>[WelcomeChoice.continueWithout]);
      expect(find.text(WelcomeCopy.onDeviceCaption), findsOneWidget);
      // Still announced as a button, and as one that is off.
      expect(
        tester.getSemantics(find.text(WelcomeCopy.createLabel)),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
      semantics.dispose();
    });

    testWidgets('the AI check is offered with its button off',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: AiCheckOffer(onDeviceOnly: true)),
      ));

      final FilledButton send =
          tester.widget(find.widgetWithText(FilledButton, 'Check with AI'));
      expect(send.onPressed, isNull);
      expect(find.textContaining(availableFrom18), findsOneWidget);
    });

    test('a signed-in account has nothing to sync to', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Stored(minor)),
          signedInUserProvider.overrideWith(
            (Ref ref) => Stream<User?>.value(_SignedInAs('generic-uid')),
          ),
          verificationPendingProvider.overrideWith(_Verified.new),
        ],
      );
      addTearDown(container.dispose);
      container.listen(signedInUserProvider, (_, __) {});
      container.listen(syncTargetProvider, (_, __) {});
      await container.read(settingsProvider.future);
      await container.read(signedInUserProvider.future);
      expect(container.read(signedInUserProvider).value, isNotNull);

      expect(container.read(syncTargetProvider), isNull);
    });

    test('the collection stays off whatever was answered before', () async {
      final _RecordingSwitches switches = _RecordingSwitches();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Stored(const AppSettings(
              adult: false, shareUsage: true, sendCrashReports: true))),
          collectionSwitchesProvider.overrideWithValue(switches),
        ],
      );
      addTearDown(container.dispose);
      container.listen(collectionChoicesProvider, (_, __) {});
      await container.read(settingsProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(switches.applied, <(bool, bool)>[(false, false)]);
    });
  });
}
