import 'package:flutter/widgets.dart';

/// Hands a screen a way to move the bottom tab bar itself. The shell only acts
/// on a scroll at depth zero, so a screen that puts a pager of its own between
/// the two has to report from inside it.
class NavBarScroll extends InheritedWidget {
  const NavBarScroll({
    super.key,
    required this.report,
    required this.show,
    required super.child,
  });

  final bool Function(UserScrollNotification) report;

  /// Brings the bar back whatever the scroll is doing.
  final VoidCallback show;

  static NavBarScroll? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NavBarScroll>();

  @override
  bool updateShouldNotify(NavBarScroll oldWidget) =>
      report != oldWidget.report || show != oldWidget.show;
}

/// Whether a list has moved far enough to move the tab bar: toward its start
/// to bring it in, or [towardEnd] to take it away. A finger lifting leaves a
/// pixel or two of movement either way, so what counts is how far the list
/// moves, not that it turned.
class NavBarReturn {
  NavBarReturn({this.towardEnd = false});

  static const double after = 8;

  final bool towardEnd;

  double? _moved;

  bool get waiting => _moved != null;

  void start() => _moved = 0;

  /// Starts waiting, or answers true to move the bar now: a list already at
  /// its end can't scroll [after] dp further, so a push there is meant. Not
  /// for a scroll view with a list inside it, like Stats' header, which sits
  /// at its end whenever the list below it is the one moving.
  bool begin(ScrollMetrics list, {bool hasListInside = false}) {
    if (towardEnd && !hasListInside && list.extentAfter <= 0) {
      stop();
      return true;
    }
    start();
    return false;
  }

  void stop() => _moved = null;

  /// [delta] is a scroll update's `scrollDelta`, negative toward the start.
  /// Stats splits one drag between its header and its page, and each update
  /// carries only its own share, so adding them all counts the drag once.
  bool scrolled(double delta) {
    final double? moved = _moved;
    if (moved == null) return false;
    final double now = moved + (towardEnd ? delta : -delta);
    if (now < after) {
      _moved = now;
      return false;
    }
    _moved = null;
    return true;
  }
}
