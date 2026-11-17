import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../widgets/common.dart';
import 'tour_stops.dart';

/// Runs the tour over whatever is on screen and completes when it is
/// finished or skipped. Recording that is the caller's job, so a replay and
/// the first run end the same way.
///
/// Behind the same closing cover as a dialog: the second tap of a double tap
/// on Done or Skip would otherwise land on Today underneath.
Future<void> showTour(
  BuildContext context,
  TourTargets targets, {
  List<TourStop> stops = tourStops,
}) {
  final bool still = MediaQuery.disableAnimationsOf(context);
  return withClosingCover<void>(
    context,
    (TransitionBuilder wrap) => Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: 'tour'),
        opaque: false,
        transitionDuration:
            still ? Duration.zero : const Duration(milliseconds: 200),
        reverseTransitionDuration:
            still ? Duration.zero : const Duration(milliseconds: 150),
        pageBuilder: (BuildContext context, Animation<double> a, _) =>
            wrap(context, TourOverlay(targets: targets, stops: stops)),
        transitionsBuilder:
            (BuildContext context, Animation<double> a, _, Widget child) =>
                FadeTransition(opacity: a, child: child),
      ),
    ),
  );
}

/// A dimmed screen with a hole over one target and a card beside it.
///
/// Taps anywhere but the card do nothing, so nothing in the app can change
/// while the tour is up.
class TourOverlay extends StatefulWidget {
  const TourOverlay({super.key, required this.targets, required this.stops});

  final TourTargets targets;
  final List<TourStop> stops;

  @override
  State<TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<TourOverlay> {
  int _step = 0;

  /// Null until measured, and whenever a target isn't on screen; the card
  /// then sits in the middle with no hole.
  Rect? _target;

  final FocusNode _next = FocusNode(debugLabel: 'tour next');

  TourStop get _stop => widget.stops[_step];

  @override
  void dispose() {
    _next.dispose();
    super.dispose();
  }

  /// Measured after layout, every frame the tour builds: a rotation or a
  /// text size change moves the target, and so does the bar settling in.
  void _measureLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final Rect? found = _measure();
      if (found != _target) setState(() => _target = found);
    });
  }

  Rect? _measure() {
    RenderObject? find(TourTarget? t) => t == null
        ? null
        : widget.targets.keyFor(t).currentContext?.findRenderObject();
    final RenderObject? target = find(_stop.target) ?? find(_stop.orTarget);
    final RenderObject? self = context.findRenderObject();
    if (target is! RenderBox || self is! RenderBox) return null;
    if (!target.attached || !target.hasSize || !self.hasSize) return null;
    final Rect box =
        target.localToGlobal(Offset.zero, ancestor: self) & target.size;
    final double? cap = _stop.maxWidth;
    if (cap == null || box.width <= cap) return box;
    return Rect.fromCenter(center: box.center, width: cap, height: box.height);
  }

  void _go(int step) {
    // Measured now rather than next frame: the screen behind can't move while
    // the tour is up, and a frame with the old hole would flash the card.
    setState(() {
      _step = step;
      _target = _measure();
    });
    _next.requestFocus();
  }

  /// Once only: Skip and the system Back in the same frame would otherwise
  /// pop the shell's route along with the tour's.
  void _end() {
    if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    _measureLater();
    final AppPalette p = context.palette;
    final bool still = MediaQuery.disableAnimationsOf(context);
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final TourStop stop = _stop;
    final Rect? target = _target;
    final RRect? hole = target == null
        ? null
        : RRect.fromRectAndRadius(
            target.inflate(stop.gap),
            Radius.circular(stop.radius ?? (target.height / 2 + stop.gap)),
          );

    final Color card = p.isDark ? p.surfaceHigher : p.surface;
    _Scrim scrim(RRect? r) => _Scrim(
          hole: r,
          scrim: p.isDark ? const Color(0xB8000000) : const Color(0x9E0E0A28),
          ring: p.isDark
              ? p.accent.withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.9),
        );
    return PopScope(
      canPop: false,
      // System Back steps back, and on the first stop leaves, like Skip.
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        _step == 0 ? _end() : _go(_step - 1);
      },
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Tour',
        // Keeps the app underneath out of reach of a screen reader too.
        child: BlockSemantics(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final Size size = box.biggest;
              final _CardPlace place = _CardPlace.of(
                size: size,
                safe: safe,
                hole: hole?.outerRect,
              );
              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: ExcludeSemantics(
                        // With no hole yet there is nothing to glide from,
                        // so the first one appears where it is.
                        child: hole == null
                            ? CustomPaint(painter: scrim(null))
                            : TweenAnimationBuilder<RRect>(
                                tween: _RRectTween(end: hole),
                                duration: still
                                    ? Duration.zero
                                    : const Duration(milliseconds: 260),
                                curve: Curves.easeOutCubic,
                                builder: (BuildContext context, RRect r, _) =>
                                    CustomPaint(painter: scrim(r)),
                              ),
                      ),
                    ),
                  ),
                  if (place.caretX != null)
                    Positioned(
                      left: place.caretX! - 8,
                      top: place.above ? place.edge - 1 : place.edge - 8 + 1,
                      child: ExcludeSemantics(
                        child: CustomPaint(
                          size: const Size(16, 8),
                          painter: _Caret(color: card, pointsDown: place.above),
                        ),
                      ),
                    ),
                  Positioned(
                    left: place.left,
                    width: place.width,
                    top: place.above ? null : place.edge,
                    bottom: place.above ? size.height - place.edge : null,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: place.maxHeight),
                      child: _TourCard(
                        // A new subtree per stop, so the live region below is
                        // a new node and is read out on every step.
                        key: ValueKey<int>(_step),
                        colour: card,
                        step: _step,
                        count: widget.stops.length,
                        stop: stop,
                        nextFocus: _next,
                        onSkip: _end,
                        onBack: _step == 0 ? null : () => _go(_step - 1),
                        onNext: _step == widget.stops.length - 1
                            ? _end
                            : () => _go(_step + 1),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Where the card goes: on whichever side of the hole has more room, near
/// the hole, and never wider than reads well on a tablet.
class _CardPlace {
  const _CardPlace({
    required this.left,
    required this.width,
    required this.above,
    required this.edge,
    required this.maxHeight,
    this.caretX,
  });

  factory _CardPlace.of({
    required Size size,
    required EdgeInsets safe,
    required Rect? hole,
  }) {
    const double margin = 16;
    const double reach = 14;
    final double width = math.min(size.width - 2 * margin, 380);
    if (hole == null) {
      return _CardPlace(
        left: (size.width - width) / 2,
        width: width,
        above: false,
        edge: safe.top + margin,
        maxHeight: size.height - safe.vertical - 2 * margin,
      );
    }
    final double left =
        (hole.center.dx - width / 2).clamp(margin, size.width - margin - width);
    final double room = hole.top - safe.top;
    final double roomBelow = size.height - safe.bottom - hole.bottom;
    final bool above = room >= roomBelow;
    final double edge = above ? hole.top - reach : hole.bottom + reach;
    return _CardPlace(
      left: left,
      width: width,
      above: above,
      edge: edge,
      maxHeight: math.max(
        120,
        (above ? room : roomBelow) - reach - margin,
      ),
      caretX: hole.center.dx.clamp(left + 24, left + width - 24),
    );
  }

  final double left;
  final double width;
  final bool above;

  /// The card's bottom when [above], its top otherwise.
  final double edge;
  final double maxHeight;
  final double? caretX;
}

class _TourCard extends StatelessWidget {
  const _TourCard({
    super.key,
    required this.colour,
    required this.step,
    required this.count,
    required this.stop,
    required this.nextFocus,
    required this.onSkip,
    required this.onBack,
    required this.onNext,
  });

  final Color colour;
  final int step;
  final int count;
  final TourStop stop;
  final FocusNode nextFocus;
  final VoidCallback onSkip;
  final VoidCallback? onBack;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String position = 'Step ${step + 1} of $count';
    final bool last = step == count - 1;
    return Material(
      color: colour,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      position.toUpperCase(),
                      style: TextStyle(
                        fontSize: AppType.labelSmall,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: AppColors.inkOn(
                          p.accent,
                          p.copyWith(surface: colour),
                        ),
                      ),
                    ),
                  ),
                ),
                TextButton(onPressed: onSkip, child: const Text('Skip')),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Semantics(
                    liveRegion: true,
                    header: true,
                    label: '$position. ${stop.title}',
                    child: ExcludeSemantics(
                      child: Text(
                        stop.title,
                        style: TextStyle(
                          fontSize: AppType.headlineSmall,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    stop.body,
                    style: TextStyle(
                      fontSize: AppType.bodyLarge,
                      height: 1.45,
                      fontWeight: FontWeight.w500,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 14, 14),
            child: Row(
              children: <Widget>[
                ExcludeSemantics(child: _Dots(step: step, count: count)),
                const SizedBox(width: 12),
                Expanded(
                  child: OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 8,
                    overflowSpacing: 8,
                    children: <Widget>[
                      if (onBack != null)
                        OutlinedButton(
                          onPressed: onBack,
                          child: const Text('Back'),
                        ),
                      FilledButton(
                        focusNode: nextFocus,
                        autofocus: true,
                        onPressed: onNext,
                        child: Text(last ? 'Done' : 'Next'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.step, required this.count});

  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < count; i++)
          Container(
            margin: const EdgeInsets.only(right: 5),
            width: i == step ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i <= step ? p.accent : p.outline,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

class _Scrim extends CustomPainter {
  const _Scrim({required this.hole, required this.scrim, required this.ring});

  final RRect? hole;
  final Color scrim;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final Path shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    final RRect? r = hole;
    if (r != null) shade.addRRect(r);
    canvas.drawPath(shade, Paint()..color = scrim);
    if (r != null) {
      canvas.drawRRect(
        r,
        Paint()
          ..color = ring
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_Scrim old) =>
      old.hole != hole || old.scrim != scrim || old.ring != ring;
}

class _Caret extends CustomPainter {
  const _Caret({required this.color, required this.pointsDown});

  final Color color;
  final bool pointsDown;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = pointsDown
        ? (Path()
          ..moveTo(0, 0)
          ..lineTo(size.width, 0)
          ..lineTo(size.width / 2, size.height)
          ..close())
        : (Path()
          ..moveTo(0, size.height)
          ..lineTo(size.width, size.height)
          ..lineTo(size.width / 2, 0)
          ..close());
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Caret old) =>
      old.color != color || old.pointsDown != pointsDown;
}

/// Moves the hole from stop to stop.
class _RRectTween extends Tween<RRect> {
  _RRectTween({required RRect end}) : super(begin: end, end: end);

  @override
  RRect lerp(double t) => RRect.lerp(begin, end, t)!;
}
