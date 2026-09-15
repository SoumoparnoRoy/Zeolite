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
