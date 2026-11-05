import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/features/launch/first_run_choices_screen.dart';
import 'package:zeolite/features/settings/privacy_section.dart';
import 'package:zeolite/services/age_signals.dart';
import 'package:zeolite/services/backup_service.dart';
import 'package:zeolite/services/collection_switches.dart';
import 'package:zeolite/services/firebase/app_check_starter.dart';
import 'package:zeolite/state/auth_providers.dart';
import 'package:zeolite/state/privacy_providers.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_notifications.dart';

/// Play's reply, held until the test lets it through.
class _HeldPlay extends AgeSignals {
  final Completer<PlayAge> reply = Completer<PlayAge>();

  @override
  Future<PlayAge> check() => reply.future;
}

class _RecordingSwitches implements CollectionSwitches {
  final List<(bool, bool)> applied = <(bool, bool)>[];

  @override
  Future<void> apply({required bool usage, required bool crashes}) async =>
      applied.add((usage, crashes));
}

/// An automatic backup whose file write the test completes by hand.
class _HeldBackup implements BackupService {
  final Completer<BackupDestination?> written = Completer<BackupDestination?>();

  @override
  Future<BackupDestination?> runAutoBackup({
    required bool enabled,
    required DateTime? lastAt,
    String? folderUri,
    DateTime? nowOverride,
  }) =>
      written.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoAppCheck implements AppCheckStarter {
  @override
  Future<void> activate() async {}
}

Map<Object?, Object?> _shared(int? lower, int? upper, {String? change}) =>
    <Object?, Object?>{
      'status': 'shared',
      'lower': lower,
      'upper': upper,
      'change': change,
    };

Future<ProviderContainer> _container(AppSettings stored,
    {BackupService? backup}) async {
  await SettingsService().save(stored);
  final ProviderContainer container = ProviderContainer(overrides: [
    notificationsProvider.overrideWithValue(QuietNotifications()),
    if (backup != null) backupServiceProvider.overrideWithValue(backup),
  ]);
  await container.read(settingsProvider.future);
  return container;
}

Future<AppSettings> _after(AppSettings stored, PlayAge age) async {
  final ProviderContainer container = await _container(stored);
  addTearDown(container.dispose);
  await container.read(privacyChoicesProvider).applyPlayAge(age);
  // Read back from the store, so the answer is one a restart keeps.
  return SettingsService().load();
}

/// The first-run screen while anything is unanswered, the app otherwise, the
/// way `_Bootstrap` chooses.
Widget _app(AgeSignals play, {Widget? home, _RecordingSwitches? switches}) {
  return ProviderScope(
    overrides: [
      ageSignalsProvider.overrideWithValue(play),
      appCheckStarterProvider.overrideWithValue(_NoAppCheck()),
      collectionSwitchesProvider
          .overrideWithValue(switches ?? _RecordingSwitches()),
      notificationsProvider.overrideWithValue(QuietNotifications()),
      signedInUserProvider.overrideWith((Ref ref) => Stream<User?>.value(null)),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          ref.watch(playAgeProvider);
          ref.watch(collectionChoicesProvider);
          final AppSettings? settings = ref.watch(settingsProvider).value;
          if (settings == null) return const SizedBox();
          if (home != null) return home;
          return settings.needsPrivacyChoices
              ? FirstRunChoicesScreen(settings: settings)
              : const Text('the app');
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

  group('what a reply means', () {
    test('a range whose top is under 18 is under 18, every default band', () {
      expect(AgeSignals.derive(_shared(0, 12)), PlayAge.under18);
      expect(AgeSignals.derive(_shared(13, 15)), PlayAge.under18);
      expect(AgeSignals.derive(_shared(16, 17)), PlayAge.under18);
      expect(AgeSignals.derive(_shared(18, null)), PlayAge.adult);
    });

    test('custom ranges: only an open range from 18 up is an adult', () {
      expect(AgeSignals.derive(_shared(13, 16)), PlayAge.under18);
      // 17+ or 15+ might still be under 18, so they say nothing.
      expect(AgeSignals.derive(_shared(17, null)), PlayAge.none);
      expect(AgeSignals.derive(_shared(15, null)), PlayAge.none);
    });

    test('nothing shared, or nothing readable, is no signal', () {
      expect(AgeSignals.derive(_shared(null, null)), PlayAge.none);
      expect(AgeSignals.derive(<Object?, Object?>{'status': 'not_shared'}),
          PlayAge.none);
      expect(AgeSignals.derive(null), PlayAge.none);
      expect(AgeSignals.derive(<Object?, Object?>{}), PlayAge.none);
      expect(
          AgeSignals.derive(
              <Object?, Object?>{'status': 'shared', 'lower': '18'}),
          PlayAge.none);
    });

    test('verification required is its own answer', () {
      expect(
          AgeSignals.derive(
              <Object?, Object?>{'status': 'verification_required'}),
          PlayAge.unverified);
    });

    test('every error code is no signal', () {
      for (final int code in <int>[-1, -2, -3, -4, -5, -6, -7, -8, -9, -10]) {
        expect(
            AgeSignals.derive(
                <Object?, Object?>{'status': 'error', 'code': code}),
            PlayAge.none,
            reason: 'code $code');
      }
      expect(
          AgeSignals.derive(
              <Object?, Object?>{'status': 'error', 'code': -100}),
          PlayAge.none);
    });

    test('a pending or declined change keeps the person where they are', () {
      for (final String change in <String>['approved', 'pending', 'declined']) {
        expect(AgeSignals.derive(_shared(13, 15, change: change)),
            PlayAge.under18);
        expect(AgeSignals.derive(_shared(18, null, change: change)),
            PlayAge.adult);
      }
    });
  });

  group('asking Play', () {
    const MethodChannel channel = MethodChannel('test/age_signals');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('reads the bridge reply', () async {
      messenger.setMockMethodCallHandler(
          channel, (MethodCall call) async => _shared(13, 15));
      expect(await const AgeSignals(channel: channel).check(), PlayAge.under18);
    });

    test('a platform error is no signal', () async {
      messenger.setMockMethodCallHandler(channel,
          (MethodCall call) async => throw PlatformException(code: 'x'));
      expect(await const AgeSignals(channel: channel).check(), PlayAge.none);
    });

    test('no bridge at all is no signal', () async {
      expect(await const AgeSignals(channel: channel).check(), PlayAge.none);
    });

    test('a reply slower than the timeout is no signal', () {
      fakeAsync((FakeAsync async) {
        final Completer<Object?> never = Completer<Object?>();
        messenger.setMockMethodCallHandler(
            channel, (MethodCall call) => never.future);
        PlayAge? result;
        const AgeSignals(channel: channel)
            .check()
            .then((PlayAge age) => result = age);
        async.elapse(AgeSignals.timeout - const Duration(milliseconds: 1));
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 2));
        expect(result, PlayAge.none);
      });
    });
  });

  group('applying the answer', () {
    test('under 18 at the first run locks on-device mode without asking',
        () async {
      final AppSettings s = await _after(const AppSettings(), PlayAge.under18);
      expect(s.adult, isFalse);
      expect(s.ageFrom, AgeFrom.play);
      expect(s.ageLockedByPlay, isTrue);
      expect(s.needsPrivacyChoices, isFalse);
    });

    test('under 18 overrides a yes the user gave', () async {
      final AppSettings s = await _after(
          const AppSettings(
              adult: true,
              ageFrom: AgeFrom.user,
              shareUsage: true,
              sendCrashReports: true),
          PlayAge.under18);
      expect(s.ageLockedByPlay, isTrue);
      expect(s.usageAllowed, isFalse);
      expect(s.crashReportsAllowed, isFalse);
    });

    test('18 or over answers the age, never the two choices', () async {
      final AppSettings s = await _after(const AppSettings(), PlayAge.adult);
      expect(s.adult, isTrue);
      expect(s.ageFrom, AgeFrom.play);
      expect(s.shareUsage, isNull);
      expect(s.sendCrashReports, isNull);
      expect(s.needsPrivacyChoices, isTrue);
    });

    test('18 or over leaves a no the user chose alone', () async {
      final AppSettings s = await _after(
          const AppSettings(adult: false, ageFrom: AgeFrom.user),
          PlayAge.adult);
      expect(s.adult, isFalse);
      expect(s.ageFrom, AgeFrom.user);
      expect(s.ageLockedByPlay, isFalse);
    });

    test('18 or over lifts a Play lock and leaves the age unanswered',
        () async {
      for (final AgeFrom from in <AgeFrom>[
        AgeFrom.play,
        AgeFrom.playUnverified
      ]) {
        final AppSettings s = await _after(
            AppSettings(adult: false, ageFrom: from), PlayAge.adult);
        expect(s.adult, isNull, reason: from.name);
        expect(s.ageFrom, isNull, reason: from.name);
        expect(s.needsPrivacyChoices, isTrue, reason: from.name);
      }
    });

    test('lifting a lock asks for both collection choices again', () async {
      final AppSettings s = await _after(
          const AppSettings(
              adult: false,
              ageFrom: AgeFrom.play,
              shareUsage: true,
              sendCrashReports: true),
          PlayAge.adult);
      expect(s.shareUsage, isNull);
      expect(s.sendCrashReports, isNull);
    });

    test('a lock that lands during the automatic backup stays', () async {
      final _HeldBackup backup = _HeldBackup();
      final ProviderContainer container = await _container(
          const AppSettings(
              adult: true, ageFrom: AgeFrom.user, autoBackupEnabled: true),
          backup: backup);
      addTearDown(container.dispose);

      final Future<void> run =
          container.read(backupActionsProvider).maybeRunAutoBackup();
      await container
          .read(privacyChoicesProvider)
          .applyPlayAge(PlayAge.under18);
      backup.written.complete(BackupDestination.appFolder);
      await run;

      final AppSettings s = await SettingsService().load();
      expect(s.ageLockedByPlay, isTrue);
      expect(s.lastAutoBackupAt, isNotNull);
    });

    test('verification required locks on-device mode and skips the question',
        () async {
      final AppSettings s =
          await _after(const AppSettings(), PlayAge.unverified);
      expect(s.adult, isFalse);
      expect(s.ageFrom, AgeFrom.playUnverified);
      expect(s.ageLockedByPlay, isTrue);
      expect(s.needsPrivacyChoices, isFalse);
    });

    test('a later shared range replaces the verification lock', () async {
      final AppSettings minor = await _after(
          const AppSettings(adult: false, ageFrom: AgeFrom.playUnverified),
          PlayAge.under18);
      expect(minor.ageFrom, AgeFrom.play);
      expect(minor.ageLockedByPlay, isTrue);
    });

    test('no signal changes nothing, a lock included', () async {
      expect((await _after(const AppSettings(), PlayAge.none)).adult, isNull);
      for (final AgeFrom from in <AgeFrom>[
        AgeFrom.play,
        AgeFrom.playUnverified
      ]) {
        final AppSettings s = await _after(
            AppSettings(adult: false, ageFrom: from), PlayAge.none);
        expect(s.ageLockedByPlay, isTrue, reason: from.name);
      }
    });

    test('a user answer is marked as the user\'s', () async {
      final ProviderContainer container = await _container(const AppSettings());
      addTearDown(container.dispose);
      await container.read(privacyChoicesProvider).setAdult(true);
      expect((await SettingsService().load()).ageFrom, AgeFrom.user);
    });

    test('where the answer came from stays on the device', () {
      final Map<String, Object?> json =
          const AppSettings(adult: false, ageFrom: AgeFrom.play).toJson();
      expect(json.keys, isNot(contains('ageFrom')));
      const AppSettings here = AppSettings(adult: false, ageFrom: AgeFrom.play);
      final AppSettings restored = AppSettings.fromJson(json).onDeviceOf(here);
      expect(restored.ageLockedByPlay, isTrue);
    });
  });

  group('on screen', () {
    testWidgets('the age question shows while Play has not answered',
        (WidgetTester tester) async {
      final _HeldPlay play = _HeldPlay();
      await tester.pumpWidget(_app(play));
      await tester.pumpAndSettle();
      expect(find.text(FirstRunChoicesScreen.ageQuestion), findsOneWidget);

      // A late under-18 reply moves past the question without a tap.
      play.reply.complete(PlayAge.under18);
      await tester.pumpAndSettle();
      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('Play saying 18 or over goes straight to the two choices',
        (WidgetTester tester) async {
      final _HeldPlay play = _HeldPlay();
      await tester.pumpWidget(_app(play));
      await tester.pumpAndSettle();
      play.reply.complete(PlayAge.adult);
      await tester.pumpAndSettle();

      expect(find.text(FirstRunChoicesScreen.ageQuestion), findsNothing);
      expect(find.text(FirstRunChoicesScreen.usageTitle), findsOneWidget);
      for (final SegmentedButton<bool> choice
          in tester.widgetList<SegmentedButton<bool>>(
              find.byType(SegmentedButton<bool>))) {
        expect(choice.selected, isEmpty);
      }
    });

    testWidgets('after a lock lifts, consent is asked again from nothing',
        (WidgetTester tester) async {
      await SettingsService().save(const AppSettings(
          adult: true,
          ageFrom: AgeFrom.user,
          shareUsage: true,
          sendCrashReports: true));
      final _RecordingSwitches switches = _RecordingSwitches();
      await tester.pumpWidget(_app(_HeldPlay(), switches: switches));
      await tester.pumpAndSettle();
      final PrivacyChoices choices =
          ProviderScope.containerOf(tester.element(find.text('the app')))
              .read(privacyChoicesProvider);

      await choices.applyPlayAge(PlayAge.under18);
      await tester.pumpAndSettle();
      await choices.applyPlayAge(PlayAge.adult);
      await tester.pumpAndSettle();
      expect(find.text(FirstRunChoicesScreen.ageQuestion), findsOneWidget);

      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(find.text(FirstRunChoicesScreen.usageTitle), findsOneWidget);
      for (final SegmentedButton<bool> choice
          in tester.widgetList<SegmentedButton<bool>>(
              find.byType(SegmentedButton<bool>))) {
        expect(choice.selected, isEmpty);
      }
      final FilledButton next =
          tester.widget(find.widgetWithText(FilledButton, 'Continue'));
      expect(next.onPressed, isNull);
      // Collection was on before the lock; nothing turns it back on yet.
      expect(switches.applied.last, (false, false));
    });

    testWidgets('the Settings switch is locked under a Play under-18',
        (WidgetTester tester) async {
      await SettingsService()
          .save(const AppSettings(adult: false, ageFrom: AgeFrom.play));
      final _HeldPlay play = _HeldPlay();
      await tester.pumpWidget(_app(play,
          home: const Scaffold(
              body: SingleChildScrollView(child: PrivacySection()))));
      await tester.pumpAndSettle();

      expect(find.text(PrivacySection.playUnder18), findsOneWidget);
      expect(find.text('Open Play Store'), findsNothing);
      final Switch toggle = tester.widget(find.byType(Switch).first);
      expect(toggle.onChanged, isNull);
      await tester.tap(find.text('18 or older'));
      await tester.pumpAndSettle();
      expect((await SettingsService().load()).adult, isFalse);

      // A later start saying 18 or over unlocks it and asks again.
      play.reply.complete(PlayAge.adult);
      await tester.pumpAndSettle();
      expect((await SettingsService().load()).adult, isNull);
    });

    testWidgets('verification required says why and links to the Play Store',
        (WidgetTester tester) async {
      await SettingsService().save(
          const AppSettings(adult: false, ageFrom: AgeFrom.playUnverified));
      await tester.pumpWidget(_app(_HeldPlay(),
          home: const Scaffold(
              body: SingleChildScrollView(child: PrivacySection()))));
      await tester.pumpAndSettle();

      expect(find.text(PrivacySection.playUnverified), findsOneWidget);
      expect(find.text('Open Play Store'), findsOneWidget);
      final Switch toggle = tester.widget(find.byType(Switch).first);
      expect(toggle.onChanged, isNull);
    });

    testWidgets('the user\'s own no can still be switched back',
        (WidgetTester tester) async {
      await SettingsService()
          .save(const AppSettings(adult: false, ageFrom: AgeFrom.user));
      await tester.pumpWidget(_app(_HeldPlay(),
          home: const Scaffold(
              body: SingleChildScrollView(child: PrivacySection()))));
      await tester.pumpAndSettle();

      final Switch toggle = tester.widget(find.byType(Switch).first);
      expect(toggle.onChanged, isNotNull);
      expect(find.text(PrivacySection.playUnder18), findsNothing);
    });
  });

  group('where the signal may go', () {
    // Play's User Data policy: never measured, reported, synced, logged or
    // sent.
    final List<File> dart = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();
    String rel(File f) => f.path.replaceAll(r'\', '/');

    test('only the age code and the screens it drives name it', () {
      const Set<String> allowed = <String>{
        'lib/services/age_signals.dart',
        'lib/state/privacy_providers.dart',
        'lib/data/settings/app_settings.dart',
        'lib/features/settings/privacy_section.dart',
      };
      final RegExp names = RegExp(r'\b(PlayAge|AgeFrom|ageFrom|ageSignals)\b');
      final List<String> outside = <String>[
        for (final File f in dart)
          if (!allowed.contains(rel(f)) && names.hasMatch(f.readAsStringSync()))
            rel(f),
      ];
      expect(outside, isEmpty);
    });

    test('the age code imports nothing that can send, log or report', () {
      final String source =
          File('lib/services/age_signals.dart').readAsStringSync();
      final List<String> imports =
          RegExp(r"^import '([^']+)';", multiLine: true)
              .allMatches(source)
              .map((RegExpMatch m) => m[1]!)
              .toList();
      expect(imports, <String>['package:flutter/services.dart']);
      for (final String call in <String>[
        'print(',
        'debugPrint(',
        'log(',
        'reportError('
      ]) {
        expect(source, isNot(contains(call)));
      }
    });

    test('the bridge never logs and never reads the install id', () {
      final String kotlin = File(
              'android/app/src/main/kotlin/com/soumoparno/zeolite/AgeSignalsBridge.kt')
          .readAsStringSync();
      expect(kotlin, isNot(contains('Log.')));
      expect(kotlin, isNot(contains('installId()')));
      expect(kotlin, isNot(contains('println')));
    });

    test('sync and backup rows never carry it', () {
      for (final AgeFrom from in AgeFrom.values) {
        final AppSettings answered = AppSettings(adult: false, ageFrom: from);
        const AppSettings plain = AppSettings(adult: false);
        expect(answered.toJson(), plain.toJson(), reason: from.name);
        expect(
            SyncItem.settings(answered).fields, SyncItem.settings(plain).fields,
            reason: from.name);
      }
    });
  });
}
