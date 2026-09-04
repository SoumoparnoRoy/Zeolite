import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import 'launch_geometry.dart';

/// Where the sequence is going once the animation is over.
enum LaunchLanding {
  /// First run: the crystal rises and the welcome screen's copy comes in
  /// underneath it.
  welcome,

  /// Every run after: the splash fades off the app, which is already built
  /// behind it.
  today,
}

/// The colours the sequence draws in, all from the user's own accent so the
/// launch matches the app it opens.
@immutable
class LaunchColors {
  const LaunchColors({
    required this.canvas,
    required this.surfaceHigh,
    required this.accent,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.present,
    required this.absent,
    required this.cancelled,
  });

  /// Always the dark palette: at these alphas the lattice is close to
  /// invisible on a light canvas, and a splash is a brand moment rather than a
  /// screen that has to follow the theme.
  factory LaunchColors.of(AccentColour accent) {
    final AppPalette p = AppPalette.dark.withAccent(accent);
    return LaunchColors(
      canvas: p.canvas,
      surfaceHigh: p.surfaceHigh,
      accent: p.accent,
      text: p.textPrimary,
      textSecondary: p.textSecondary,
      textTertiary: p.textTertiary,
      present: p.present,
      absent: p.absent,
      cancelled: p.cancelled,
    );
  }

  final Color canvas;
  final Color surfaceHigh;
  final Color accent;
  final Color text;
  final Color textSecondary;
  final Color textTertiary;
  final Color present;
  final Color absent;
  final Color cancelled;

  @override
  bool operator ==(Object other) =>
      other is LaunchColors && other.accent == accent && other.text == text;

  @override
  int get hashCode => Object.hash(accent, text);

  Color forMark(LaunchMark mark) => switch (mark) {
        LaunchMark.present => present,
        LaunchMark.absent => absent,
        LaunchMark.cancelled => cancelled,
      };
}

/// The welcome screen's bottom stack, measured once so the painted heading and
/// the real buttons under it cannot drift apart.
///
/// Everything scales together with the text scaler rather than the type
/// growing inside fixed slots, which is what makes a bottom stack overlap
/// itself on a short screen.
@immutable
class WelcomeMetrics {
  const WelcomeMetrics({
    required this.size,
    required this.scale,
    required this.frame,
    required this.bottomInset,
  });

  /// The sequence was composed at 340 × 700. Everything geometric is a
  /// multiple of that rather than a fixed size, or the crystal ends up a small
  /// object in the middle of a tablet instead of the same picture larger.
  static double frameFor(Size size) =>
      math.min(size.width / 340, size.height / 700);

  /// A column of full-width buttons across a tablet is a phone layout
  /// stretched, so the copy stops at a readable width and centres.
  static const double maxCopyWidth = 460;

  static const double buttonHeight = 52;
  static const double buttonGap = 10;
  static const double buttonInset = 26;
  static const double buttonRadius = 14;

  /// One line of the terms couplet, and the caption under the last button.
  static const double termsLine = 18;
  static const double captionLine = 16;

  /// Terms couplet to the first button, and last button to the caption.
  static const double termsGap = 24;
  static const double captionGap = 22;

  static const double bottomMargin = 30;

  final Size size;

  /// The viewer's text scaling.
  final double scale;

  /// How much bigger this screen is than the one the design was drawn on.
  final double frame;

  final double bottomInset;

  double get buttonH => buttonHeight * scale;

  double get copyWidth => math.min(size.width, maxCopyWidth);

  double get stackHeight =>
      (termsLine * 2 + termsGap + captionGap + captionLine) * scale +
      buttonH * 3 +
      buttonGap * scale * 2;

  double get stackTop => size.height - bottomMargin - bottomInset - stackHeight;

  /// Thirty above the first terms line's baseline, which itself sits about a
  /// third of a line below the stack's top edge. Scaled by [frame] like the
  /// heading it has to clear, or a tablet's larger type closes the gap up.
  double get headingBaseline => stackTop - 17 * scale * frame;

  double get headingSize => 21 * scale * frame;
  double get wordmarkSize => 34 * scale * frame;
}

/// The launch sequence: one painter, one clock, no second animation.
///
/// The prototype at `Documents/Apps/Zeolite/launch-sequence-prototype.html` is
/// the spec — `paintNodes`, `paintCages` and `headingFromWordmark` there are
/// what these methods are ported from.
class LaunchPainter extends CustomPainter {
  LaunchPainter({
    required Animation<double> clock,
    required this.short,
    required this.landing,
    required this.colors,
    required this.metrics,
    required this.textScale,
  })  : _clock = clock,
        super(repaint: clock);

  final Animation<double> _clock;
  final bool short;
  final LaunchLanding landing;
  final LaunchColors colors;
  final WelcomeMetrics? metrics;
  final double textScale;

  double get mainEnd => short ? LaunchTiming.shortEnd : LaunchTiming.mainEnd;

  double get handoffLength => landing == LaunchLanding.welcome
      ? LaunchTiming.welcomeHandoff
      : LaunchTiming.todayHandoff;

  double get totalEnd => mainEnd + handoffLength;

  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _fill = Paint()..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    final double raw = _clock.value;
    final double t = math.min(raw, totalEnd);
    canvas.drawRect(Offset.zero & size, _fill..color = colors.canvas);

    if (t <= mainEnd) {
      short ? _short(canvas, size, t) : _sequence(canvas, size, t);
      return;
    }
    // Staged on the clamped clock, turned by the raw one: the sequence stops
    // on its last mark while the crystal goes on rotating under the copy.
    final double p = seg(t, mainEnd, totalEnd);
    landing == LaunchLanding.welcome
        ? _welcome(canvas, size, p, raw)
        : _leaving(canvas, size, p, t);
  }

  double _spinFrom() => short ? 0 : LaunchTiming.foldStart;

  double _fieldGrown(double t) => short
      ? seg(t, LaunchTiming.shortFieldStart, LaunchTiming.shortFieldEnd)
      : seg(t, LaunchTiming.fieldStart, LaunchTiming.fieldEnd);

  double _crystalScale(Size size) =>
      LaunchGeometry.scale * WelcomeMetrics.frameFor(size);

  void _sequence(Canvas canvas, Size size, double t) {
    final double cy = size.height * 0.5;
    _paintCages(
      canvas,
      size,
      cx: size.width / 2,
      cy: cy,
      scale: _crystalScale(size),
      rotY: LaunchGeometry.spinAt(t, LaunchTiming.foldStart),
      dist: LaunchGeometry.near,
      alpha: LaunchGeometry.fieldLaunch,
      grown: _fieldGrown(t),
    );
    _paintNodes(
      canvas,
      t,
      cx: size.width / 2,
      cy: cy,
      scale: _crystalScale(size),
      fold: seg(t, LaunchTiming.foldStart, LaunchTiming.foldEnd),
      opacity: 1,
      spinFrom: LaunchTiming.foldStart,
      dist: LaunchGeometry.near,
      frame: WelcomeMetrics.frameFor(size),
    );
    if (t < LaunchTiming.wordStart) return;
    _paintWord(
      canvas,
      size,
      cy,
      metrics?.wordmarkSize ?? 34 * textScale,
      from: LaunchTiming.wordStart,
      to: LaunchTiming.sweepEnd,
      dotFrom: LaunchTiming.sweepEnd - 120,
      dotTo: LaunchTiming.wordEnd,
      t: t,
    );
  }

  /// The short setting is the week skipped, not a second animation: the
  /// crystal starts assembled and the wordmark reveals over it.
  void _short(Canvas canvas, Size size, double t) {
    final double cy = size.height * 0.5;
    _paintCages(
      canvas,
      size,
      cx: size.width / 2,
      cy: cy,
      scale: _crystalScale(size),
      rotY: LaunchGeometry.spinAt(t, 0),
      dist: LaunchGeometry.near,
      alpha: LaunchGeometry.fieldLaunch * seg(t, 0, 420),
      grown: _fieldGrown(t),
    );
    _paintNodes(
      canvas,
      t,
      cx: size.width / 2,
      cy: cy,
      scale: _crystalScale(size),
      fold: 1,
      opacity: seg(t, 0, 420),
      spinFrom: 0,
      dist: LaunchGeometry.near,
      frame: WelcomeMetrics.frameFor(size),
    );
    _paintWord(
      canvas,
      size,
      cy,
      metrics?.wordmarkSize ?? 34 * textScale,
      from: 60,
      to: 640,
      dotFrom: 540,
      dotTo: LaunchTiming.shortEnd,
      t: t,
    );
  }

  /// The hand-off is a camera move, not a scene change: the crystal rises, the
  /// eye steps back, and the lattice that has been growing since the wordmark
  /// started is still arriving while it does.
  void _welcome(Canvas canvas, Size size, double p, double clock) {
    final WelcomeMetrics m = metrics ??
        WelcomeMetrics(
          size: size,
          scale: textScale,
          frame: WelcomeMetrics.frameFor(size),
          bottomInset: 0,
        );
    final double e = easeInOut(p);
    final double cy = lerpd(size.height * 0.5, size.height * 0.30, e);
    final double frame = WelcomeMetrics.frameFor(size);
    final double scale = lerpd(LaunchGeometry.scale * frame, 40 * frame, e);
    final double dist = lerpd(LaunchGeometry.near, LaunchGeometry.far, e);
    final double rotY = LaunchGeometry.spinAt(clock, _spinFrom());

    _paintCages(
      canvas,
      size,
      cx: size.width / 2,
      cy: cy,
      scale: scale,
      rotY: rotY,
      dist: dist,
      alpha: lerpd(LaunchGeometry.fieldLaunch, 1, seg(p, 0, 0.7)),
      grown: _fieldGrown(clock),
    );
    _paintNodes(
      canvas,
      clock,
      cx: size.width / 2,
      cy: cy,
      scale: scale,
      fold: 1,
      opacity: 1,
      spinFrom: _spinFrom(),
      dist: dist,
      frame: frame,
    );
    _scrim(canvas, size, seg(p, 0.22, 0.8));
    _heading(canvas, size, m, e);
  }

  /// Every launch after the first. The crystal fades rather than settling —
  /// the screen behind this one belongs to the app, and is not a place to
  /// leave something spinning every day.
  void _leaving(Canvas canvas, Size size, double p, double clock) {
    final double e = easeInOut(p);
    final double cy = size.height * 0.5;
    _paintCages(
      canvas,
      size,
      cx: size.width / 2,
      cy: cy,
      scale: _crystalScale(size),
      rotY: LaunchGeometry.spinAt(clock, _spinFrom()),
      dist: LaunchGeometry.near,
      alpha: LaunchGeometry.fieldLaunch * (1 - e),
      grown: _fieldGrown(clock),
    );
    _paintNodes(
      canvas,
      clock,
      cx: size.width / 2,
      cy: cy,
      scale: _crystalScale(size),
      fold: 1,
      opacity: 1 - e,
      spinFrom: _spinFrom(),
      dist: LaunchGeometry.near,
      frame: WelcomeMetrics.frameFor(size),
    );
    _wordmark(
      canvas,
      size,
      cy,
      metrics?.wordmarkSize ?? 34 * textScale,
      edge: double.infinity,
      dotP: 1,
      ghost: false,
      opacity: 1 - e,
    );
  }

  /// The cages the week did not become. Accent only, never attendance
  /// colours — the coloured nodes are the days that were actually marked, and
  /// that distinction is worth keeping once the field gets big.
  void _paintCages(
    Canvas canvas,
    Size size, {
    required double cx,
    required double cy,
    required double scale,
    required double rotY,
    required double dist,
    required double alpha,
    required double grown,
  }) {
    if (alpha <= 0.01) return;
    // Widths and radii are pixel sizes, so they grow with the composition
    // rather than staying phone-sized on a screen twice the size.
    final double frame = WelcomeMetrics.frameFor(size);

    for (final LaunchCage cage in LaunchGeometry.extension) {
      final double a = alpha *
          easeOut(clampd(
            (grown - cage.wave * LaunchGeometry.fieldSpread) /
                (1 - LaunchGeometry.fieldSpread),
            0,
            1,
          ));
      if (a <= 0.01) continue;

      // Rotation swings the outer shells through the frame, so the cull runs
      // per frame rather than being decided once from the offset.
      final Projected mid = LaunchGeometry.project(
          cage.at, rotY, LaunchGeometry.tilt, scale, cx, cy, dist);
      final double margin = 2.6 * scale * mid.persp;
      if (mid.x < -margin ||
          mid.x > size.width + margin ||
          mid.y < -margin ||
          mid.y > size.height + margin) {
        continue;
      }

      final List<Projected> pts = <Projected>[
        for (final Vec3 v in LaunchGeometry.cageVerts)
          LaunchGeometry.project(
              v + cage.at, rotY, LaunchGeometry.tilt, scale, cx, cy, dist),
      ];

      for (final List<int> edge in LaunchGeometry.cageEdges) {
        final Projected qa = pts[edge[0]], qb = pts[edge[1]];
        final double d = LaunchGeometry.depthCue((qa.persp + qb.persp) / 2);
        _stroke
          ..strokeWidth = (0.7 + 1.1 * d * d) * frame
          ..color =
              colors.accent.withValues(alpha: (0.045 + 0.13 * d * d * d) * a);
        canvas.drawLine(Offset(qa.x, qa.y), Offset(qb.x, qb.y), _stroke);
      }

      final List<Projected> sorted = pts.toList()
        ..sort((Projected m, Projected n) => n.z.compareTo(m.z));
      for (final Projected q in sorted) {
        final double d = LaunchGeometry.depthCue(q.persp);
        final double r = (1.2 + 1.8 * d * d) * frame;
        // A wide faint disc under each node reads as glow without a gradient,
        // which matters at this many nodes a frame.
        _fill.color = colors.accent.withValues(alpha: 0.05 * d * a);
        canvas.drawCircle(Offset(q.x, q.y), r * 2.6, _fill);
        _fill.color =
            colors.accent.withValues(alpha: (0.10 + 0.22 * d * d * d) * a);
        canvas.drawCircle(Offset(q.x, q.y), r, _fill);
      }
    }
  }

  /// The whole node list at whatever stage the clock says. [fold] of 0 is the
  /// flat week and 1 the settled crystal; the hand-off and the short version
  /// pass 1 and the grid half simply never applies.
  void _paintNodes(
    Canvas canvas,
    double t, {
    required double cx,
    required double cy,
    required double scale,
    required double fold,
    required double opacity,
    required double spinFrom,
    required double dist,
    required double frame,
  }) {
    if (opacity <= 0.01) return;

    final double settled = easeInOut(fold);
    final double rotY = LaunchGeometry.spinAt(t, spinFrom);
    // The plane tips as a whole while the blocks are still moving
    // individually, which is what makes the week turn into space rather than
    // slide across it.
    final double tilt = LaunchGeometry.tilt * settled;

    final List<LaunchNode> nodes = LaunchGeometry.nodes;
    final List<double> own = List<double>.filled(nodes.length, 1);
    final List<Projected> at = List<Projected>.filled(
      nodes.length,
      const Projected(0, 0, 0, 1),
    );

    for (int i = 0; i < nodes.length; i++) {
      final LaunchNode n = nodes[i];
      final double o = fold >= 1
          ? 1
          : easeOut(clampd(
              (settled - n.delay) / (1 - LaunchGeometry.maxDelay), 0, 1));
      own[i] = o;
      at[i] = LaunchGeometry.project(
        Vec3(
          lerpd(n.from.x, n.to.x, o),
          lerpd(n.from.y, n.to.y, o),
          lerpd(n.from.z, n.to.z, o),
        ),
        rotY,
        tilt,
        scale,
        cx,
        cy,
        dist,
      );
    }

    // A bond only exists once both the blocks that make it have arrived, and
    // it grows outward from its own midpoint.
    final int perCage = LaunchGeometry.cageVerts.length;
    for (int cage = 0; cage < LaunchGeometry.pair.length; cage++) {
      for (final List<int> edge in LaunchGeometry.cageEdges) {
        final int ia = cage * perCage + edge[0];
        final int ib = cage * perCage + edge[1];
        final double grow = seg(math.min(own[ia], own[ib]), 0.72, 1);
        if (grow <= 0) continue;
        final Projected qa = at[ia], qb = at[ib];
        final double mx = (qa.x + qb.x) / 2, my = (qa.y + qb.y) / 2;
        final double depth = (qa.persp + qb.persp) / 2;
        _stroke
          ..strokeWidth = frame
          ..color =
              colors.accent.withValues(alpha: 0.15 * depth * grow * opacity);
        canvas.drawLine(
          Offset(lerpd(mx, qa.x, grow), lerpd(my, qa.y, grow)),
          Offset(lerpd(mx, qb.x, grow), lerpd(my, qb.y, grow)),
          _stroke,
        );
      }
    }

    // Far nodes first, so near ones sit on top of them.
    final List<int> order = List<int>.generate(nodes.length, (int i) => i)
      ..sort((int x, int y) => at[y].z.compareTo(at[x].z));

    for (final int i in order) {
      final LaunchNode n = nodes[i];
      final Projected p = at[i];
      final double o = own[i];
      final double dot = 0.36 * p.persp;

      if (!n.isCell) {
        final double show = seg(o, 0.18, 0.88);
        if (show <= 0) continue;
        _fill.color =
            colors.forMark(n.mark).withValues(alpha: dot * show * opacity);
        canvas.drawCircle(Offset(p.x, p.y), 2 * p.persp * frame, _fill);
        continue;
      }

      final double build =
          fold >= 1 ? 1 : seg(t, n.buildDelay, n.buildDelay + 340);
      if (build <= 0) continue;
      final double be = easeOut(build);

      final double flip = n.marked ? seg(t, n.flipDelay, n.flipDelay + 320) : 0;
      final double squash = flip > 0 && o < 0.1
          ? math.max(math.cos(flip * math.pi).abs(), 0.04)
          : 1;

      // Square to node: the half-size and the corner radius converge, so one
      // rounded rectangle covers both ends without a second shape.
      final double half = lerpd(
        (LaunchGeometry.cell / 2) * frame * lerpd(0.7, 1, be),
        2 * p.persp * frame,
        o,
      );
      final double radius = lerpd(8 * frame, half, o);
      final bool filled = flip > 0.5;

      canvas.save();
      canvas.translate(p.x, p.y);
      canvas.scale(squash, 1);
      final RRect box = RRect.fromRectAndRadius(
        Rect.fromLTWH(-half, -half, half * 2, half * 2),
        Radius.circular(radius),
      );
      // An unmarked day has no colour of its own, so it settles as an accent
      // node rather than losing its outline to nothing.
      _fill.color = (filled ? colors.forMark(n.mark) : colors.accent)
          .withValues(alpha: lerpd(filled ? 0.92 : 0, dot, o) * opacity);
      canvas.drawRRect(box, _fill);
      if (!filled) {
        _stroke
          ..strokeWidth = 1.5 * frame
          ..color =
              colors.accent.withValues(alpha: lerpd(0.5 * be, 0, o) * opacity);
        canvas.drawRRect(box, _stroke);
      }
      canvas.restore();
    }
  }

  /// Fades the lattice into the canvas before the copy starts, so nothing
  /// reads through it.
  void _scrim(Canvas canvas, Size size, double p) {
    if (p <= 0) return;
    final double top = size.height * 0.30;
    final double mid = size.height * 0.60;
    canvas.drawRect(
      Rect.fromLTRB(0, top, size.width, mid),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, top),
          Offset(0, mid),
          <Color>[
            colors.canvas.withValues(alpha: 0),
            colors.canvas.withValues(alpha: 0.96 * p),
          ],
        ),
    );
    canvas.drawRect(
      Rect.fromLTRB(0, mid, size.width, size.height),
      _fill..color = colors.canvas.withValues(alpha: 0.96 * p),
    );
  }

  double _baselineOf(TextPainter painter) =>
      painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);

  TextPainter _text(String value, double size, Color color) {
    return TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: AppFonts.sans,
          fontWeight: FontWeight.w800,
          fontSize: size,
          color: color,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _paintWord(
    Canvas canvas,
    Size size,
    double cy,
    double fontSize, {
    required double from,
    required double to,
    required double dotFrom,
    required double dotTo,
    required double t,
  }) {
    final double reveal = easeInOut(seg(t, from, to));
    final TextPainter word = _text('Zeolite', fontSize, colors.text);
    final double x = size.width / 2 - word.width / 2;
    final double edge = lerpd(x - 24, x + word.width + 6, reveal);

    _wordmark(canvas, size, cy, fontSize,
        edge: edge, dotP: seg(t, dotFrom, dotTo), ghost: true, opacity: 1);

    // The leading edge of the reveal carries the accent with it.
    if (reveal > 0 && reveal < 1) {
      canvas.drawRect(
        Rect.fromLTWH(edge - 46, cy - fontSize, 54, fontSize * 2),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(edge - 46, 0),
            Offset(edge + 8, 0),
            <Color>[
              colors.accent.withValues(alpha: 0),
              colors.accent.withValues(alpha: 0.55),
            ],
          ),
      );
    }
  }

  void _wordmark(
    Canvas canvas,
    Size size,
    double cy,
    double fontSize, {
    required double edge,
    required double dotP,
    required bool ghost,
    required double opacity,
  }) {
    final TextPainter word =
        _text('Zeolite', fontSize, colors.text.withValues(alpha: opacity));
    final double x = size.width / 2 - word.width / 2;
    final double top = cy - word.height / 2;

    if (ghost) {
      _text('Zeolite', fontSize, colors.text.withValues(alpha: 0.05))
          .paint(canvas, Offset(x, top));
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(
      x - 24,
      cy - fontSize * 1.2,
      edge.isFinite ? edge : size.width,
      cy + fontSize * 1.2,
    ));
    word.paint(canvas, Offset(x, top));
    canvas.restore();

    if (dotP > 0) {
      _dot(canvas, x, top + _baselineOf(word), fontSize, dotP, opacity,
          dropFrom: cy - fontSize * 1.9);
    }
  }

  /// The accent dot that lands on the i. [dropFrom] null leaves it in place,
  /// which is what the heading needs once the drop has already happened.
  void _dot(
    Canvas canvas,
    double x,
    double baseline,
    double fontSize,
    double p,
    double opacity, {
    double? dropFrom,
  }) {
    final double lead = _text('Zeol', fontSize, colors.text).width;
    final double stem = _text('i', fontSize, colors.text).width;
    final double cx = x + lead + stem / 2;
    final double rest = baseline - fontSize * 0.64;
    final double cy =
        dropFrom == null ? rest : lerpd(dropFrom, rest, easeOut(p));
    _fill.color = colors.accent.withValues(alpha: opacity);
    canvas.drawCircle(
      Offset(cx, cy),
      fontSize * 0.075 * math.min(1, dropFrom == null ? 1 : p * 2.4),
      _fill,
    );
  }

  /// The splash's wordmark does not fade out and a heading fade in — the same
  /// mark shrinks, drops and slides right until it is the last word of
  /// "Welcome to Zeolite", with the first two words fading in beside it.
  void _heading(Canvas canvas, Size size, WelcomeMetrics m, double e) {
    final double fontSize = lerpd(m.wordmarkSize, m.headingSize, e);
    final TextPainter pre = _text('Welcome to ', m.headingSize, colors.text);
    final TextPainter whole =
        _text('Welcome to Zeolite', m.headingSize, colors.text);
    final double lineX = size.width / 2 - whole.width / 2;

    final TextPainter word = _text('Zeolite', fontSize, colors.text);
    final double x =
        lerpd(size.width / 2 - word.width / 2, lineX + pre.width, e);
    // Interpolated as a box top so it leaves the wordmark exactly where the
    // wordmark was and lands on the heading's real baseline, rather than half
    // a line box below it.
    final double top = lerpd(
      size.height * 0.5 - word.height / 2,
      m.headingBaseline - _baselineOf(word),
      e,
    );
    final double baseline = top + _baselineOf(word);

    word.paint(canvas, Offset(x, top));
    _dot(canvas, x, baseline, fontSize, 1, 1);

    final double show = seg(e, 0.45, 0.9);
    if (show > 0) {
      final TextPainter lead = _text(
          'Welcome to ', m.headingSize, colors.text.withValues(alpha: show));
      lead.paint(
        canvas,
        Offset(lerpd(lineX + 10, lineX, show), baseline - _baselineOf(lead)),
      );
    }
  }

  @override
  bool shouldRepaint(LaunchPainter old) =>
      old.colors != colors ||
      old.short != short ||
      old.landing != landing ||
      old.textScale != textScale;
}
