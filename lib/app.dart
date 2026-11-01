import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import 'core/app_theme.dart';
import 'data/settings/app_settings.dart';
import 'features/launch/first_run_choices_screen.dart';
import 'features/launch/launch_screen.dart';
import 'features/launch/update_required_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/stats/stats_screen.dart';
import 'features/stats/stats_view.dart';
import 'features/timetable/timetable_screen.dart';
import 'features/timetable/week_widget_image.dart';
import 'features/today/today_screen.dart';
import 'state/home_widget_providers.dart';
import 'state/notion_sync_providers.dart';
import 'state/privacy_providers.dart';
import 'state/providers.dart';
import 'state/sync_providers.dart';
import 'widgets/common.dart';
import 'widgets/kept_alive.dart';
import 'widgets/nav_bar_scroll.dart';
import 'widgets/shell_routes.dart';

class ZeoliteApp extends ConsumerWidget {
  const ZeoliteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Until settings have loaded there is no stored choice to honour, so the
    // app follows the system, which is also what a fresh install settles on.
    final AppSettings? settings = ref.watch(settingsProvider).value;
    final AppThemeMode mode = settings?.themeMode ?? AppThemeMode.system;
    final AccentColour accent = settings?.accentColour ?? AccentColour.violet;

    // Watched for their lifetime rather than their value; see the providers.
    // App Check first, so a sync started at launch carries its token.
    ref.watch(appCheckProvider);
    ref.watch(syncSchedulerProvider);
    ref.watch(notionSchedulerProvider);
    ref.watch(homeWidgetSyncProvider);
    ref.watch(weekWidgetImageProvider);
    ref.watch(homeWidgetMarkWatcherProvider);
    ref.watch(collectionChoicesProvider);

    final FirebaseAnalyticsObserver? observer =
        ref.watch(analyticsObserverProvider);

    return MaterialApp(
      title: 'Zeolite',
      debugShowCheckedModeBanner: false,
      // Reaches the pushed screens only, and only because they carry a
      // `RouteSettings` name — the tabs are an [IndexedStack], so [RootShell]
      // reports those itself.
      navigatorObservers: <NavigatorObserver>[
        shellRoutes,
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

/// Asks the first-run questions if they are still open, plays the launch
/// sequence, then decides between the first-run setup flow and the main shell.
class _Bootstrap extends ConsumerStatefulWidget {
  const _Bootstrap();

  @override
  ConsumerState<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends ConsumerState<_Bootstrap> {
  /// Once per launch, so not a setting: `welcomeShown` says whether the
  /// welcome screen is part of the sequence, not whether it has run.
  bool _launched = false;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<AppSettings> settings = ref.watch(settingsProvider);

    return settings.when(
      // The sequence draws in the chosen accent, so it waits for the stored
      // choice rather than starting violet and changing colour part way.
      loading: () => ColoredBox(color: context.palette.canvas),
      // Reported where the load fails, in SettingsController, not from here:
      // build runs again on every frame the error stays up.
      error: (Object error, StackTrace stack) => Scaffold(
        body: LoadFailed(onRetry: () => ref.invalidate(settingsProvider)),
      ),
      data: (AppSettings value) {
        if (value.needsPrivacyChoices) {
          return FirstRunChoicesScreen(settings: value);
        }
        if (!_launched) {
          return LaunchScreen(
            settings: value,
            onFinished: () => setState(() => _launched = true),
          );
        }
        // Checked behind the app rather than before it, so a slow or absent
        // answer costs nothing; a late one replaces whatever is showing.
        if (ref.watch(buildTooOldProvider).value == true) {
          return const UpdateRequiredScreen();
        }
        return value.onboarded ? const RootShell() : const OnboardingScreen();
      },
    );
  }
}

/// Bottom-navigation shell holding the four main screens.
///
/// A [PageView], so a screen follows your finger across rather than waiting
/// for you to let go. Each page is kept alive so scroll positions survive.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  /// Reading takes the bar away and reaching back brings it in. Null leaves it
  /// as it is — including for the day pills, which scroll sideways inside the
  /// screen's own list and would otherwise flicker the bar on every day.
  static bool? navVisibleFor(
    ScrollDirection direction, {
    required int depth,
    required Axis axis,
    required double maxExtent,
    bool atTop = false,
  }) {
    if (depth != 0 || axis != Axis.vertical) return null;
    return switch (direction) {
      // Never conditional, or a screen that stopped scrolling once the bar
      // went could never get it back.
      ScrollDirection.forward => true,
      // A screen that already fits has no room to win.
      ScrollDirection.reverse => maxExtent > 0 ? false : null,
      // A fling back to the top can end before any forward drag is reported.
      ScrollDirection.idle => atTop ? true : null,
    };
  }

  /// At the top only if the list around it is too. On a tablet, Stats' page
  /// fits under its header, so it never leaves its top while the header does
  /// the scrolling, and the bar came back as every fling settled.
  static bool atTop(ScrollMetrics list, {ScrollMetrics? around}) =>
      list.pixels <= list.minScrollExtent &&
      (around == null || around.pixels <= around.minScrollExtent);

  /// Where a `zeolite://open?tab=` link lands, so each widget opens the screen
  /// it is a view of. An unknown name returns null and the app opens where it
  /// was, which is what a widget older than the tab it names should do.
  static int? tabForLink(Uri? uri) {
    if (uri == null || uri.host != 'open') return null;
    final int index = shellTabs.indexOf(uri.queryParameters['tab'] ?? '');
    return index == -1 ? null : index;
  }

  /// Where a tapped notification lands. The warning is about percentages, so
  /// it opens Stats; both reminders are about a class you are meant to mark,
  /// which is Today. Resolved through [shellTabs] so reordering the tabs cannot
  /// leave this pointing at the wrong screen.
  static int? tabForPayload(String? payload) {
    if (payload == null) return null;
    if (payload == 'danger') return shellTabs.indexOf('stats');
    if (payload == 'evening' || payload.startsWith('class:')) {
      return shellTabs.indexOf('today');
    }
    return null;
  }

  /// Pushed pages a notification or widget tap may close on its way to a tab:
  /// ones that only show something or save as they go. A page holding typed
  /// input or a choice not yet made (the account form, an import, a Notion
  /// step, a merge) stays open, and so does any sheet or dialog.
  static const Set<String> plainPages = <String>{
    'subjects',
    'settings_categories',
    'settings_term',
    'settings_teachingDay',
    'settings_roomsAndTags',
    'settings_appearance',
    'settings_notifications',
    'settings_notion',
    'settings_yourData',
    'settings_licences',
    'licence',
    'launcher_icon',
    'attendance_log',
  };

  static bool isPlainPage(Route<dynamic> route) =>
      route is PageRoute && plainPages.contains(route.settings.name);

  /// Closes [plainPages] from the top down, stopping at the first route that
  /// is not one.
  static void closePlainPages(NavigatorState navigator) =>
      navigator.popUntil((Route<dynamic> r) => r.isFirst || !isPlainPage(r));

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> with RouteAware {
  static const List<Widget> _screens = <Widget>[
    TodayScreen(),
    TimetableScreen(),
    StatsScreen(),
    SettingsScreen(),
  ];

  late final PageController _pages =
      PageController(initialPage: ref.read(selectedTabProvider));

  // Held rather than read each time: dispose needs it, and ref is gone by then.
  late final ValueNotifier<String?> _tapped =
      ref.read(notificationsProvider).tappedPayload;

  StreamSubscription<Uri?>? _linkSub;

  AppLifecycleListener? _lifecycle;

  /// A time or zone set while the app is open, from `MainActivity`.
  static const MethodChannel _clockChanges = MethodChannel('zeolite/clock');

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        ref.invalidate(trayAccessProvider);
        ref.read(clockProvider.notifier).tick();
        _maybeBackUp();
      },
    );
    _clockChanges.setMethodCallHandler((MethodCall _) async {
      ref.read(clockProvider.notifier).tick();
    });
    _tapped.addListener(_openTappedNotification);
    // Set by a link elsewhere too. A swipe sets it already on the page, which
    // the check leaves alone.
    ref.listenManual<int>(selectedTabProvider, (int? _, int tab) {
      if (_pages.hasClients && _pages.page?.round() != tab) _slideTo(tab);
    });
    // The stream carries a tap that arrived while the app was running; only
    // the launch link carries the one that started it. Not app_links — a
    // widget tap comes in on home_widget's LAUNCH action, not as a VIEW.
    _linkSub = HomeWidget.widgetClicked.listen(_openLink);
    unawaited(HomeWidget.initiallyLaunchedFromHomeWidget().then(_openLink));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _report();
      _maybeBackUp();
      // A tap that launched the app was recorded before this shell existed.
      _openTappedNotification();
    });
  }

  /// Due at most once a day and a date comparison the rest of the time, so a
  /// launch and every return to the app can both ask.
  void _maybeBackUp() =>
      unawaited(ref.read(backupActionsProvider).maybeRunAutoBackup());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<void>? route = ModalRoute.of(context);
    if (route != null) shellRoutes.subscribe(this, route);
  }

  /// Back from a pushed page with the bar still tucked away, the bottom of the
  /// screen takes taps meant for a tab.
  @override
  void didPopNext() => _showNav(true);

  @override
  void dispose() {
    shellRoutes.unsubscribe(this);
    _tapped.removeListener(_openTappedNotification);
    unawaited(_linkSub?.cancel());
    _lifecycle?.dispose();
    _clockChanges.setMethodCallHandler(null);
    _pages.dispose();
    super.dispose();
  }

  void _openLink(Uri? uri) {
    final int? tab = RootShell.tabForLink(uri);
    if (tab == null || !mounted) return;
    _openFromOutside(tab);
  }

  /// A tab switched behind an open page only shows once that page is closed.
  void _openFromOutside(int tab) {
    RootShell.closePlainPages(Navigator.of(context));
    _select(tab);
  }

  /// Sliding two screens at once in the time it takes to slide one is a blur,
  /// so a jump between distant tabs cuts instead.
  void _slideTo(int index) {
    if (!_pages.hasClients) return;
    final double from = _pages.page ?? index.toDouble();
    if ((from - index).abs() > 1) {
      _pages.jumpToPage(index);
      return;
    }
    unawaited(_pages.animateToPage(index,
        duration: AppMotion.pageSlide, curve: AppMotion.pageCurve));
  }

  void _openTappedNotification() {
    final int? tab = RootShell.tabForPayload(_tapped.value);
    if (_tapped.value != null) _tapped.value = null;
    if (tab == null || !mounted) return;
    _openFromOutside(tab);
  }

  /// A tap on the bar or a notification; a drag moves the pager itself.
  void _select(int index) => _slideTo(index);

  /// Fires on crossing half way, so the bar lights up before it settles.
  void _onPageChanged(int index) {
    // A field left focused on the page behind would raise the keyboard here.
    dropFocus();
    // A tab arrived at with the bar hidden would look like it has no way back.
    _showNav(true);
    ref.read(selectedTabProvider.notifier).select(index);
    _report(index);
  }

  bool _navVisible = true;

  /// A list near its end when the bar starts coming back. It is moved up as
  /// the bar takes its room, or its last card would end up under the bar and
  /// Add class.
  ScrollPosition? _liftWithBar;
  double _liftOwed = 0;
  double? _bodyHeight;

  void _showNav(bool visible) {
    if (_navVisible == visible) return;
    if (!visible) _liftWithBar = null;
    setState(() => _navVisible = visible);
  }

  /// Only near the end: further up, the list moving under your finger would
  /// look like a jump, and the bar covering a card there is ordinary reading.
  ScrollPosition? _nearEnd(UserScrollNotification notification) {
    final BuildContext? scrollable = notification.context;
    final double bar = (NavigationBarTheme.of(context).height ?? 80) +
        MediaQuery.paddingOf(context).bottom;
    if (scrollable == null || notification.metrics.extentAfter >= bar) {
      return null;
    }
    _liftOwed = 0;
    return Scrollable.maybeOf(scrollable)?.position;
  }

  /// Runs during layout, before the list's own, so the list is placed at its
  /// new offset in the same frame the bar grows. A correction rather than a
  /// jump, which would cancel the drag that brought the bar back.
  ///
  /// It moves no further than the list's end. That end is the last known
  /// extent plus what the bar took this frame, but only once the list already
  /// ran past the screen; a list that fitted waits a frame for its real
  /// extent, then catches up.
  void _liftAsBarReturns(double height) {
    final double? before = _bodyHeight;
    _bodyHeight = height;
    final ScrollPosition? position = _liftWithBar;
    if (before == null || position == null || !position.hasPixels) return;
    if (height >= before) return;
    final double taken = before - height;
    _liftOwed += taken;
    final double end = position.maxScrollExtent > 0
        ? position.maxScrollExtent + taken
        : position.minScrollExtent;
    final double lift = math.min(_liftOwed, end - position.pixels);
    if (lift <= 0) return;
    position.correctBy(lift);
    _liftOwed -= lift;
  }

  /// Also reached from [TodayScreen], whose list sits a level deeper.
  bool _onScroll(UserScrollNotification notification) {
    final ScrollPosition? around = _verticalAround(notification.context);
    if (around != null && notification.metrics.axis == Axis.vertical) {
      _hasListInside[around] = true;
    }
    final bool? visible = RootShell.navVisibleFor(
      notification.direction,
      depth: notification.depth,
      axis: notification.metrics.axis,
      maxExtent: notification.metrics.maxScrollExtent,
      atTop: RootShell.atTop(notification.metrics, around: around),
    );
    if (visible == true &&
        !_navVisible &&
        notification.direction == ScrollDirection.forward) {
      _comingBackFrom = notification;
      _comingBack.start();
      _goingAway.stop();
      return false;
    }
    if (visible == false && _navVisible) {
      _comingBack.stop();
      final ScrollPosition? reporter = notification.context
          ?.findAncestorStateOfType<ScrollableState>()
          ?.position;
      final bool hasListInside =
          reporter != null && (_hasListInside[reporter] ?? false);
      if (!_goingAway.begin(notification.metrics,
          hasListInside: hasListInside)) {
        return false;
      }
    }
    if (visible == true && !_navVisible) _liftWithBar = _nearEnd(notification);
    if (visible != null) {
      _comingBack.stop();
      _goingAway.stop();
      _showNav(visible);
    }
    return false;
  }

  /// The nearest vertical scroll view around the one that reported, if any:
  /// the pagers in between scroll sideways. Looked up rather than depended
  /// on, since this runs from a notification, not a build.
  ScrollPosition? _verticalAround(BuildContext? reporter) {
    ScrollableState? outer = reporter
        ?.findAncestorStateOfType<ScrollableState>()
        ?.context
        .findAncestorStateOfType<ScrollableState>();
    while (outer != null && outer.position.axis != Axis.vertical) {
      outer = outer.context.findAncestorStateOfType<ScrollableState>();
    }
    final ScrollPosition? position = outer?.position;
    return position != null && position.hasPixels ? position : null;
  }

  /// Moving the bar either way has to be meant; see [NavBarReturn].
  final NavBarReturn _comingBack = NavBarReturn();
  final NavBarReturn _goingAway = NavBarReturn(towardEnd: true);
  UserScrollNotification? _comingBackFrom;

  /// Scroll views found around a list that reported. An [Expando], so a page
  /// that goes away takes its entry with it.
  final Expando<bool> _hasListInside = Expando<bool>();

  /// Any vertical list in the page counts, because the one that turned is
  /// the one moving.
  bool _onDrag(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is ScrollEndNotification) {
      _comingBack.stop();
      _goingAway.stop();
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;
    final double delta = notification.scrollDelta ?? 0;
    final UserScrollNotification? from = _comingBackFrom;
    if (from != null && _comingBack.scrolled(delta)) {
      if (!_navVisible) _liftWithBar = _nearEnd(from);
      _showNav(true);
    } else if (_goingAway.scrolled(delta)) {
      _showNav(false);
    }
    return false;
  }

  void _bringBarBack() => _showNav(true);

  void _report([int? index]) {
    final String tab = shellTabs[index ?? ref.read(selectedTabProvider)];
    // Stats reports its own view changes; arriving on it has to say which.
    unawaited(ref.read(analyticsProvider).screen(
          tab == 'stats' ? ref.read(statsViewProvider).screenName : tab,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final int index = ref.watch(selectedTabProvider);
    final int today = shellTabs.indexOf('today');
    // Back steps out to Today before it leaves the app.
    return PopScope(
      canPop: index == today,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _select(today);
      },
      child: Scaffold(
        // The day pills, Home's date pager and the settings sliders are deeper
        // in the tree, so they take a sideways drag before this pager sees it.
        // Measured here, above the screens, to lift a list as the bar comes
        // back; see [_liftAsBarReturns].
        body: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            _liftAsBarReturns(constraints.maxHeight);
            return NavBarScroll(
              report: _onScroll,
              show: _bringBarBack,
              child: PageView(
                controller: _pages,
                onPageChanged: _onPageChanged,
                children: <Widget>[
                  for (final Widget screen in _screens)
                    // Listened per page rather than around the pager, which
                    // would otherwise count as a level and hide every screen's
                    // own scroll from [RootShell.navVisibleFor].
                    KeptAlive(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onDrag,
                        child: NotificationListener<UserScrollNotification>(
                          onNotification: _onScroll,
                          child: screen,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
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
            onEnd: () => _liftWithBar = null,
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
