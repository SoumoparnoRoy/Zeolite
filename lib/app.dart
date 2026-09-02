import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_theme.dart';
import 'data/settings/app_settings.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/stats/stats_screen.dart';
import 'features/timetable/timetable_screen.dart';
import 'features/today/today_screen.dart';
import 'services/notification_service.dart';
import 'state/providers.dart';
import 'state/notion_sync_providers.dart';
import 'state/sync_providers.dart';

class ZeoliteApp extends ConsumerWidget {
  const ZeoliteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Until settings have loaded there is no stored choice to honour, so the
    // app opens dark rather than flashing a light frame first.
    final AppSettings? settings = ref.watch(settingsProvider).value;
    final AppThemeMode mode = settings?.themeMode ?? AppThemeMode.dark;
    final AccentColour accent = settings?.accentColour ?? AccentColour.violet;

    // Watched for their lifetime rather than their value; see the providers.
    ref.watch(syncSchedulerProvider);
    ref.watch(notionSchedulerProvider);

    final FirebaseAnalyticsObserver? observer =
        ref.watch(analyticsObserverProvider);

    return MaterialApp(
      title: 'Zeolite',
      debugShowCheckedModeBanner: false,
      // Reaches the pushed screens only, and only because they carry a
      // `RouteSettings` name — the tabs are an [IndexedStack], so [RootShell]
      // reports those itself.
      navigatorObservers: <NavigatorObserver>[
        if (observer != null) observer,
      ],
      theme: AppTheme.light(accent),
      darkTheme: AppTheme.dark(accent),
      themeMode: switch (mode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData mq = MediaQuery.of(context);
        final double factor = AppScale.of(mq.size);
        if (factor == 1) return child!;
        return MediaQuery(
          data: mq.copyWith(textScaler: ScaledText(mq.textScaler, factor)),
          child: child!,
        );
      },
      home: const _Bootstrap(),
    );
  }
}

/// Decides between the first-run setup flow and the main shell once settings
/// have loaded.
class _Bootstrap extends ConsumerWidget {
  const _Bootstrap();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<AppSettings> settings = ref.watch(settingsProvider);

    return settings.when(
      loading: () => const Scaffold(
        body: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      ),
      error: (Object error, StackTrace stack) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Text(
              'Could not load your settings.\n$error',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.palette.textSecondary),
            ),
          ),
        ),
      ),
      data: (AppSettings value) =>
          value.onboarded ? const RootShell() : const OnboardingScreen(),
    );
  }
}

/// Bottom-navigation shell holding the four main screens.
///
/// An [IndexedStack] keeps each tab's scroll position and state alive, so
/// switching tabs feels instant rather than rebuilding from scratch.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  /// Same order as the shell's screens, so a tab added to one and not the
  /// other shows. Public so [tabForPayload] and the tests resolve through it
  /// rather than through a second copy of the ordering.
  /// Reading takes the bar away and reaching back brings it in. Null leaves it
  /// as it is — including for the day pills, which scroll sideways inside the
  /// screen's own list and would otherwise flicker the bar on every day.
  static bool? navVisibleFor(
    ScrollDirection direction, {
    required int depth,
    required Axis axis,
    required double maxExtent,
  }) {
    if (depth != 0 || axis != Axis.vertical) return null;
    return switch (direction) {
      // Never conditional, or a screen that stopped scrolling once the bar
      // went could never get it back.
      ScrollDirection.forward => true,
      // A screen that already fits has no room to win.
      ScrollDirection.reverse => maxExtent > 0 ? false : null,
      ScrollDirection.idle => null,
    };
  }

  static const List<String> tabNames = <String>[
    'today',
    'timetable',
    'stats',
    'settings',
  ];

  /// Where a tapped notification lands. The warning is about percentages, so
  /// it opens Stats; both reminders are about a class you are meant to mark,
  /// which is Today. Resolved through [tabNames] so reordering the tabs cannot
  /// leave this pointing at the wrong screen.
  static int? tabForPayload(String? payload) {
    if (payload == null) return null;
    if (payload == 'danger') return tabNames.indexOf('stats');
    if (payload == 'evening' || payload.startsWith('class:')) {
      return tabNames.indexOf('today');
    }
    return null;
  }

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  static const List<Widget> _screens = <Widget>[
    TodayScreen(),
    TimetableScreen(),
    StatsScreen(),
    SettingsScreen(),
  ];

  ValueNotifier<String?> get _tapped =>
      NotificationService.instance.tappedPayload;

  @override
  void initState() {
    super.initState();
    _tapped.addListener(_openTappedNotification);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _report();
      // A tap that launched the app was recorded before this shell existed.
      _openTappedNotification();
    });
  }

  @override
  void dispose() {
    _tapped.removeListener(_openTappedNotification);
    super.dispose();
  }

  void _openTappedNotification() {
    final int? tab = RootShell.tabForPayload(_tapped.value);
    if (_tapped.value != null) _tapped.value = null;
    if (tab == null || !mounted) return;
    _select(tab);
  }

  void _select(int index) {
    // A tab arrived at with the bar hidden would look like it has no way back.
    _showNav(true);
    ref.read(selectedTabProvider.notifier).select(index);
    _report(index);
  }

  bool _navVisible = true;

  void _showNav(bool visible) {
    if (_navVisible == visible) return;
    setState(() => _navVisible = visible);
  }

  bool _onScroll(UserScrollNotification notification) {
    final bool? visible = RootShell.navVisibleFor(
      notification.direction,
      depth: notification.depth,
      axis: notification.metrics.axis,
      maxExtent: notification.metrics.maxScrollExtent,
    );
    if (visible != null) _showNav(visible);
    return false;
  }

  void _report([int? index]) => ref
      .read(analyticsProvider)
      .screen(RootShell.tabNames[index ?? ref.read(selectedTabProvider)]);

  @override
  Widget build(BuildContext context) {
    final int index = ref.watch(selectedTabProvider);
    return Scaffold(
      body: NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: IndexedStack(index: index, children: _screens),
      ),
      // A shadow rather than a rule: the tab row is the one piece of chrome
      // that has to stay above the sheet, and a hairline read as one more
      // divider among the day rules above it.
      // Collapsed rather than slid away, so the sheet gains the room instead
      // of scrolling underneath it.
      bottomNavigationBar: ClipRect(
        clipper: const _NavBarClip(),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          heightFactor: _navVisible ? 1 : 0,
          child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.palette.navSurface,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: context.palette.isDark
                  ? Colors.black.withValues(alpha: 0.5)
                  : const Color(0x174C4696),
              blurRadius: 16,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: _select,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.today_outlined),
              selectedIcon: Icon(Icons.today_rounded),
              label: 'Today',
            ),
            NavigationDestination(
              icon: Icon(Icons.view_week_outlined),
              selectedIcon: Icon(Icons.view_week_rounded),
              label: 'Timetable',
            ),
            NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights_rounded),
              label: 'Stats',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings_rounded),
              label: 'Settings',
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Leaves a strip above the bar unclipped, since its shadow falls upward.
class _NavBarClip extends CustomClipper<Rect> {
  const _NavBarClip();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, -24, size.width, size.height);

  @override
  bool shouldReclip(CustomClipper<Rect> oldClipper) => false;
}
