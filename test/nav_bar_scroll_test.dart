import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/app.dart';
import 'package:zeolite/widgets/nav_bar_scroll.dart';

bool? _decide(
  ScrollDirection direction, {
  int depth = 0,
  Axis axis = Axis.vertical,
  double maxExtent = 900,
  bool atTop = false,
}) =>
    RootShell.navVisibleFor(direction,
        depth: depth, axis: axis, maxExtent: maxExtent, atTop: atTop);

void main() {
  group('the tab bar on scroll', () {
    test('reading down hides it, coming back up shows it', () {
      expect(_decide(ScrollDirection.reverse), isFalse);
      expect(_decide(ScrollDirection.forward), isTrue);
    });

    test('a list settling leaves it as it was, unless it is back at the top',
        () {
      expect(_decide(ScrollDirection.idle), isNull);
      expect(_decide(ScrollDirection.idle, atTop: true), isTrue);
    });

    // The week strip on Today.
    test('moving sideways is not reading', () {
      expect(_decide(ScrollDirection.reverse, axis: Axis.horizontal), isNull);
      expect(_decide(ScrollDirection.forward, axis: Axis.horizontal), isNull);
    });

    test('a list inside the screen answers for itself, not for the bar', () {
      expect(_decide(ScrollDirection.reverse, depth: 1), isNull);
    });

    // Home's list lives inside its own date pager, so what the shell sees is
    // a level deeper than what every other screen sends it. This is the
    // arrangement that puts the decision back at depth zero; lift the inner
    // listener out and the bar silently stops moving on Home alone.
    testWidgets('a screen with a pager of its own still moves the bar',
        (WidgetTester tester) async {
      final List<int> shellDepths = <int>[];
      final List<int> reportedDepths = <int>[];

      await tester.pumpWidget(MaterialApp(
        home: NotificationListener<UserScrollNotification>(
          onNotification: (UserScrollNotification n) {
            shellDepths.add(n.depth);
            return false;
          },
          child: NavBarScroll(
            report: (UserScrollNotification n) {
              reportedDepths.add(n.depth);
              return false;
            },
            show: () {},
            child: Builder(
              builder: (BuildContext context) => PageView(
                children: <Widget>[
                  NotificationListener<UserScrollNotification>(
                    onNotification: NavBarScroll.of(context)!.report,
                    child: ListView(
                      children: <Widget>[
                        for (int i = 0; i < 40; i++) const SizedBox(height: 60),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(reportedDepths, contains(0));
      expect(shellDepths, isNot(contains(0)));
    });

    test('a screen that already fits keeps its bar', () {
      expect(_decide(ScrollDirection.reverse, maxExtent: 0), isNull);
    });

    test('the bar can always come back, even with nothing left to scroll', () {
      expect(_decide(ScrollDirection.forward, maxExtent: 0), isTrue);
    });
  });

  group('bringing the bar back', () {
    test('it waits for 8 dp of scrolling back', () {
      final NavBarReturn back = NavBarReturn()..start();
      expect(back.scrolled(-5), isFalse);
      expect(back.scrolled(-2.9), isFalse);
      expect(back.scrolled(-0.1), isTrue);
      expect(back.waiting, isFalse);
    });

    // The end of a fling at a list's end, as measured on the emulator.
    test('a twitch back that settles on the end again never counts', () {
      final NavBarReturn back = NavBarReturn()..start();
      expect(back.scrolled(-2.29), isFalse);
      expect(back.scrolled(2.29), isFalse);
      back.stop();
      expect(back.scrolled(-20), isFalse);
    });

    test('each gesture starts from nothing', () {
      final NavBarReturn back = NavBarReturn()..start();
      expect(back.scrolled(-6), isFalse);
      back
        ..stop()
        ..start();
      expect(back.scrolled(-6), isFalse);
    });

    // Stats' header and page each report their part of one drag.
    test('a drag split between two lists counts once', () {
      final NavBarReturn back = NavBarReturn()..start();
      expect(back.scrolled(-3), isFalse);
      expect(back.scrolled(-5), isTrue);
    });
    test('taking it away waits for 8 dp toward the end', () {
      final NavBarReturn away = NavBarReturn(towardEnd: true)..start();
      expect(away.scrolled(5), isFalse);
      expect(away.scrolled(-1), isFalse);
      expect(away.scrolled(3.9), isFalse);
      expect(away.scrolled(0.1), isTrue);
    });

    test('at the end of a list, a push toward the end takes it away at once',
        () {
      ScrollMetrics list(double pixels) => FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 300,
            pixels: pixels,
            viewportDimension: 800,
            axisDirection: AxisDirection.down,
            devicePixelRatio: 2.75,
          );
      final NavBarReturn away = NavBarReturn(towardEnd: true);
      expect(away.begin(list(300)), isTrue);
      expect(away.waiting, isFalse);
      expect(away.begin(list(200)), isFalse);
      expect(away.waiting, isTrue);
    });

    // Stats: the header has scrolled away and sits at its end, while the
    // list below it, which is the one moving, is not at its end.
    test('a twitch toward the end with only the header at its end keeps it',
        () {
      ScrollMetrics at(double pixels, double max) => FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: max,
            pixels: pixels,
            viewportDimension: 800,
            axisDirection: AxisDirection.down,
            devicePixelRatio: 2.625,
          );
      final NavBarReturn away = NavBarReturn(towardEnd: true);
      expect(away.begin(at(298.1, 298.1), hasListInside: true), isFalse);
      expect(away.begin(at(170, 192.6)), isFalse);
      expect(away.scrolled(0.06), isFalse);
    });

    // The finger lifting at the end of the small drag that brought it back.
    test('a twitch toward the end after the bar came back keeps it', () {
      final NavBarReturn back = NavBarReturn()..start();
      final NavBarReturn away = NavBarReturn(towardEnd: true);
      expect(back.scrolled(-8.5), isTrue);
      away.start();
      expect(away.scrolled(0.06), isFalse);
    });
  });

  group('the top of a screen', () {
    ScrollMetrics at(double pixels, double max) => FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: max,
          pixels: pixels,
          viewportDimension: 800,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 2.75,
        );

    test('a list on its own is at the top when it is', () {
      expect(RootShell.atTop(at(0, 300)), isTrue);
      expect(RootShell.atTop(at(40, 300)), isFalse);
    });

    // Stats on a tablet: the page fits, and the header above it has scrolled.
    test('a list that fits under a scrolled header is not at the top', () {
      expect(RootShell.atTop(at(0, 0), around: at(292.7, 292.7)), isFalse);
      expect(RootShell.atTop(at(0, 0), around: at(0, 292.7)), isTrue);
    });
  });
}
