import 'package:flutter/material.dart';

import '../../widgets/gradient_header.dart';
import '../../widgets/nav_bar_scroll.dart';

/// One Stats page's list. It reports to the tab bar itself: the pager in
/// between hides its scrolls from the shell.
class StatsPageList extends StatelessWidget {
  const StatsPageList({super.key, required this.slivers});

  /// The pages' own side padding, inside the column's gutters.
  static const double sidePad = 20;

  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets inset = GradientScaffold.columnInset(context);
    return NotificationListener<UserScrollNotification>(
      onNotification: NavBarScroll.of(context)?.report ?? (_) => false,
      child: CustomScrollView(
        slivers: <Widget>[
          for (final Widget sliver in slivers)
            SliverPadding(padding: inset, sliver: sliver),
          const SliverToBoxAdapter(
            child: SizedBox(height: GradientScaffold.defaultBottomInset),
          ),
        ],
      ),
    );
  }
}
