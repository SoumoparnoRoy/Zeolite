import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Page snapping without the pager's own drag, so [PagerHandoff] can be the
/// only thing listening to a sideways finger.
class HandoffPagePhysics extends PageScrollPhysics {
  const HandoffPagePhysics({super.parent});

  @override
  HandoffPagePhysics applyTo(ScrollPhysics? ancestor) =>
      HandoffPagePhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => false;
}

/// A pager inside the tab pager, where a swipe past either end carries on
/// into the next tab with the same finger instead of stopping dead.
///
/// A nested pager would win the drag and keep it, so neither one takes it:
/// [controller]'s pager uses [HandoffPagePhysics], and every movement is
/// split here between it and the nearest horizontal [Scrollable] above.
class PagerHandoff extends StatefulWidget {
  const PagerHandoff({
    super.key,
    required this.controller,
    required this.child,
  });

  final PageController controller;
  final Widget child;

  /// How one movement divides between the two, in scroll pixels: positive
  /// moves the content left. An outer pager already pulled off its page goes
  /// back first; otherwise the inner one takes what it can before its edge.
  static (double inner, double outer) split({
    required double delta,
    required double outerOffset,
    required double innerPixels,
    required double innerMin,
    required double innerMax,
  }) {
    double rest = delta;
    double outer = 0;
    if (outerOffset != 0) {
      if (outerOffset.sign == rest.sign) return (0, rest);
      outer = rest.abs() > outerOffset.abs() ? -outerOffset : rest;
      rest -= outer;
    }
    final double inner =
        (innerPixels + rest).clamp(innerMin, innerMax) - innerPixels;
    return (inner, outer + rest - inner);
  }

  @override
  State<PagerHandoff> createState() => _PagerHandoffState();
}

class _PagerHandoffState extends State<PagerHandoff> {
  ScrollPosition? _outerPosition;
  double _outerStart = 0;
  Drag? _inner;
  Drag? _outer;

  ScrollPosition? _findOuter() {
    final ScrollableState? outer = Scrollable.maybeOf(context);
    if (outer == null ||
        axisDirectionToAxis(outer.axisDirection) != Axis.horizontal) {
      return null;
    }
    return outer.position;
  }

  void _start(DragStartDetails details) {
    _outerPosition = _findOuter();
    _outerStart = _outerPosition?.pixels ?? 0;
  }

  void _update(DragUpdateDetails details) {
    if (!widget.controller.hasClients) return;
    final ScrollPosition inner = widget.controller.position;
    final ScrollPosition? outer = _outerPosition;
    final (double toInner, double toOuter) = PagerHandoff.split(
      delta: -(details.primaryDelta ?? 0),
      outerOffset: outer == null ? 0 : outer.pixels - _outerStart,
      innerPixels: inner.pixels,
      innerMin: inner.minScrollExtent,
      innerMax: inner.maxScrollExtent,
    );
    if (toInner != 0) {
      (_inner ??= inner.drag(_startAt(details), () => _inner = null))
          .update(_moved(details, toInner));
    }
    if (toOuter != 0 && outer != null) {
      (_outer ??= outer.drag(_startAt(details), () => _outer = null))
          .update(_moved(details, toOuter));
    }
  }

  /// The fling goes to whichever pager the finger left off its page; the
  /// other settles where it is.
  void _end(DragEndDetails details) {
    final ScrollPosition? outer = _outerPosition;
    final bool outerMoved =
        outer != null && (outer.pixels - _outerStart).abs() > 0.5;
    final DragEndDetails still = DragEndDetails(primaryVelocity: 0);
    _outer?.end(outerMoved ? details : still);
    _inner?.end(outerMoved ? still : details);
    _inner = null;
    _outer = null;
    _outerPosition = null;
  }

  /// Removed mid-swipe, a drag left running would hold its pager off a page.
  @override
  void dispose() {
    _inner?.cancel();
    _outer?.cancel();
    super.dispose();
  }

  static DragStartDetails _startAt(DragUpdateDetails details) =>
      DragStartDetails(
        globalPosition: details.globalPosition,
        sourceTimeStamp: details.sourceTimeStamp,
      );

  static DragUpdateDetails _moved(DragUpdateDetails details, double pixels) =>
      DragUpdateDetails(
        globalPosition: details.globalPosition,
        sourceTimeStamp: details.sourceTimeStamp,
        delta: Offset(-pixels, 0),
        primaryDelta: -pixels,
      );

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: () => _end(DragEndDetails(primaryVelocity: 0)),
      child: widget.child,
    );
  }
}
