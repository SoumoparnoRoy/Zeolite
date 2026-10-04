import 'package:flutter/widgets.dart';

/// Keeps a built page alive, so a tab holds its scroll position.
class KeptAlive extends StatefulWidget {
  const KeptAlive({super.key, required this.child});

  final Widget child;

  @override
  State<KeptAlive> createState() => _KeptAliveState();
}

class _KeptAliveState extends State<KeptAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
