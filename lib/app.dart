import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_theme.dart';
import 'data/settings/app_settings.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/stats/stats_screen.dart';
import 'features/timetable/timetable_screen.dart';
import 'features/today/today_screen.dart';
import 'state/providers.dart';
import 'state/notion_sync_providers.dart';
import 'state/sync_providers.dart';

class ZeoliteApp extends ConsumerWidget {
  const ZeoliteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Until settings have loaded there is no stored choice to honour, so the
    // app opens dark rather than flashing a light frame first.
    final AppThemeMode mode =
        ref.watch(settingsProvider).value?.themeMode ?? AppThemeMode.dark;

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
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
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

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  int _index = 0;

  static const List<Widget> _screens = <Widget>[
    TodayScreen(),
    TimetableScreen(),
    StatsScreen(),
    SettingsScreen(),
  ];

  /// Same order as [_screens], so a tab added to one and not the other shows.
  static const List<String> _tabNames = <String>[
    'today',
    'timetable',
    'stats',
    'settings',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  void _report() => ref.read(analyticsProvider).screen(_tabNames[_index]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      // A shadow rather than a rule: the tab row is the one piece of chrome
      // that has to stay above the sheet, and a hairline read as one more
      // divider among the day rules above it.
      bottomNavigationBar: DecoratedBox(
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
          selectedIndex: _index,
          onDestinationSelected: (int value) {
            setState(() => _index = value);
            _report();
          },
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
    );
  }
}
