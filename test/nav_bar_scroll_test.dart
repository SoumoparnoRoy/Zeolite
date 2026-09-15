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
}) =>
    RootShell.navVisibleFor(direction,
        depth: depth, axis: axis, maxExtent: maxExtent);

void main() {
  group('the tab bar on scroll', () {
    test('reading down hides it, coming back up shows it', () {
      expect(_decide(ScrollDirection.reverse), isFalse);
      expect(_decide(ScrollDirection.forward), isTrue);
    });

    test('a list settling leaves it as it was', () {
      expect(_decide(ScrollDirection.idle), isNull);
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
}
