import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/app.dart';

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

    test('a screen that already fits keeps its bar', () {
      expect(_decide(ScrollDirection.reverse, maxExtent: 0), isNull);
    });

    test('the bar can always come back, even with nothing left to scroll', () {
      expect(_decide(ScrollDirection.forward, maxExtent: 0), isTrue);
    });
  });
}
