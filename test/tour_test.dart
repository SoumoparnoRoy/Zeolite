import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/settings/settings_pages.dart';
import 'package:zeolite/features/tour/tour_launcher.dart';
import 'package:zeolite/features/tour/tour_stops.dart';
import 'package:zeolite/state/auth_providers.dart';
import 'package:zeolite/state/providers.dart';

/// The shell stood in for: one widget per stop, keyed as the app keys them,
/// and the Settings row that replays the tour.
class _Shell extends ConsumerWidget {
  const _Shell({
    required this.onAddClass,
    required this.onBehind,
    this.hasClasses = false,
  });

  final VoidCallback onAddClass;

  /// A tap that reached the screen itself rather than one of its buttons.
  final VoidCallback onBehind;

  /// With classes, Today's add button is its FAB, under a key of its own.
  final bool hasClasses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TourTargets t = ref.watch(tourTargetsProvider);
    Widget tab(TourTarget? target, String label) => SizedBox(
          key: target == null ? null : t.keyFor(target),
          width: 90,
          height: 72,
          child: Center(child: Text(label)),
        );
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onBehind,
        child: Column(
          children: <Widget>[
            const SizedBox(height: 120),
            SizedBox(
              key: t.keyFor(TourTarget.weekStrip),
              height: 64,
              width: double.infinity,
            ),
            const Spacer(),
            FilledButton(
              key: t.keyFor(
                hasClasses ? TourTarget.addClassFab : TourTarget.addClass,
              ),
              onPressed: onAddClass,
              child: const Text('Add your first class'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => SettingsItem.tour.open(context, ref),
              child: const Text('Show tour again'),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                tab(null, 'Today'),
                tab(TourTarget.timetableTab, 'Timetable'),
                tab(TourTarget.statsTab, 'Stats'),
                tab(TourTarget.settingsTab, 'Settings'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  int addTaps = 0;
  int behindTaps = 0;

  /// The launcher waits out the tab bar's slide before measuring, on a timer
  /// that settling alone doesn't run.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  /// One launch of the app: a fresh container reading what the last one
  /// saved, the way a cold start does.
  Future<void> launch(
    WidgetTester tester, {
    double textScale = 1,
    bool hasClasses = false,
  }) async {
    addTaps = 0;
    behindTaps = 0;
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signedInUserProvider.overrideWith(
          (Ref ref) => Stream<User?>.value(null),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: TourLauncher(
            onPrepare: () {},
            child: _Shell(
              onAddClass: () => addTaps++,
              onBehind: () => behindTaps++,
              hasClasses: hasClasses,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
  }

  Finder step(int n, String title) =>
      find.bySemanticsLabel('Step $n of ${tourStops.length}. $title');

  Future<bool> seen() async => (await SettingsService().load()).tourSeen;

  group('the first launch after setup', () {
    setUp(() async {
      await SettingsService()
          .save(const AppSettings(onboarded: true, tourSeen: false));
    });

    testWidgets('opens the tour, announcing each step and focusing it',
        (WidgetTester tester) async {
      phone(tester);
      final SemanticsHandle semantics = tester.ensureSemantics();
      await launch(tester);

      for (int i = 0; i < tourStops.length; i++) {
        final Finder title = step(i + 1, tourStops[i].title);
        expect(title, findsOneWidget);
        expect(
          tester.getSemantics(title),
          isSemantics(isLiveRegion: true, isHeader: true),
        );
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'tour next',
          reason: 'focus is on the card at step ${i + 1}',
        );
        if (i < tourStops.length - 1) {
          await tester.tap(find.text('Next'));
          await tester.pumpAndSettle();
        }
      }
      expect(find.text('Done'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('keeps taps off the app underneath',
        (WidgetTester tester) async {
      phone(tester);
      await launch(tester);
      await tester.tap(find.text('Add your first class'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(addTaps, 0);
      expect(find.text('Skip'), findsOneWidget);
    });

    testWidgets('a double tap on Done goes nowhere once the tour closes',
        (WidgetTester tester) async {
      phone(tester);
      await launch(tester);
      for (int i = 1; i < tourStops.length; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      final Offset done = tester.getCenter(find.text('Done'));
      await tester.tapAt(done);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(done);
      await tester.pumpAndSettle();
      expect(find.text('Skip'), findsNothing);
      expect(behindTaps, 0);
    });

    testWidgets('once classes exist, the first stop points at the FAB',
        (WidgetTester tester) async {
      phone(tester);
      await launch(tester, hasClasses: true);
      final Rect fab = tester.getRect(find.text('Add your first class'));
      final Rect card = tester.getRect(find.ancestor(
        of: find.text('Next'),
        matching: find.byWidgetPredicate(
          (Widget w) => w is Material && w.elevation == 12,
        ),
      ));
      // The card sits beside the button it explains, not in the middle of
      // the screen as it does with no target.
      expect(card.bottom, lessThan(fab.top));
      expect(fab.top - card.bottom, lessThan(40));
    });

    testWidgets('Back steps back, and system Back on the first stop leaves',
        (WidgetTester tester) async {
      phone(tester);
      final SemanticsHandle semantics = tester.ensureSemantics();
      await launch(tester);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(step(1, tourStops.first.title), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Skip'), findsNothing);
      expect(await seen(), isTrue);
      semantics.dispose();
    });

    testWidgets('Skip ends it for good', (WidgetTester tester) async {
      phone(tester);
      await launch(tester);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('Skip'), findsNothing);
      expect(await seen(), isTrue);

      await launch(tester);
      expect(find.text('Skip'), findsNothing);
    });

    testWidgets('finishing it means the next launch goes straight in',
        (WidgetTester tester) async {
      phone(tester);
      await launch(tester);
      for (int i = 1; i < tourStops.length; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(await seen(), isTrue);

      await launch(tester);
      expect(find.text('Skip'), findsNothing);
    });

    testWidgets('fits every stop at twice the text size',
        (WidgetTester tester) async {
      phone(tester);
      await launch(tester, textScale: 2);
      for (int i = 0; i < tourStops.length; i++) {
        expect(tester.takeException(), isNull, reason: 'step ${i + 1}');
        expect(find.text('Skip'), findsOneWidget);
        if (i < tourStops.length - 1) {
          await tester.ensureVisible(find.text('Next'));
          await tester.tap(find.text('Next'));
          await tester.pumpAndSettle();
        }
      }
    });
  });

  testWidgets('Show tour again replays it from the first stop',
      (WidgetTester tester) async {
    phone(tester);
    final SemanticsHandle semantics = tester.ensureSemantics();
    await SettingsService()
        .save(const AppSettings(onboarded: true, tourSeen: true));
    await launch(tester);
    expect(find.text('Skip'), findsNothing);

    await tester.tap(find.text('Show tour again'));
    await settle(tester);
    expect(step(1, tourStops.first.title), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Skip'), findsNothing);
    expect(await seen(), isTrue);
    semantics.dispose();
  });

  group('who sees it', () {
    test('a new install does', () async {
      expect(await seen(), isFalse);
    });

    test('an install that finished setup before the tour existed does not',
        () async {
      // Stored the way an older build stored it: no tour key at all.
      await SharedPreferencesAsync().setBool('ut.onboarded', true);
      expect(await seen(), isTrue);
    });

    test('a restored backup leaves this device\'s answer alone', () {
      final AppSettings restored = AppSettings.fromJson(
        const AppSettings().toJson(),
      ).onDeviceOf(const AppSettings(onboarded: true, tourSeen: false));
      expect(restored.tourSeen, isFalse);
    });
  });
}
