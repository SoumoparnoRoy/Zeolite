import 'dart:math' as math;

/// The launch sequence's geometry, with no Flutter in it: the crystal, the
/// week that becomes it, and the lattice that grows around them both.
///
/// Everything here is built once at startup and never changes, so the painter
/// does projection and interpolation per frame and nothing else.

double clampd(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// Progress through the window [a] → [b], clamped at both ends.
double seg(double t, double a, double b) => clampd((t - a) / (b - a), 0, 1);

double easeOut(double p) => 1 - math.pow(1 - p, 3).toDouble();

double easeInOut(double p) =>
    p < 0.5 ? 4 * p * p * p : 1 - math.pow(-2 * p + 2, 3).toDouble() / 2;

double lerpd(double a, double b, double p) => a + (b - a) * p;

/// Deterministic, so every launch marks the same days. The alternative — the
/// user's own attendance — would greet someone with their absences before the
/// app has finished opening.
double hash(num a, num b) {
  final double s = math.sin(a * 127.1 + b * 311.7) * 43758.5453;
  return s - s.floorToDouble();
}

class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  Vec3 operator +(Vec3 other) => Vec3(x + other.x, y + other.y, z + other.z);

  double get planarLength => math.sqrt(x * x + y * y);
}

/// A point after projection: screen position, depth, and the perspective
/// factor that depth produced.
class Projected {
  const Projected(this.x, this.y, this.z, this.persp);

  final double x;
  final double y;
  final double z;
  final double persp;
}

/// Which of the three states a settled node carries. Resolved to colours by
/// the painter so the sequence uses the app's own attendance palette.
enum LaunchMark { present, absent, cancelled }

class LaunchCage {
  const LaunchCage(this.at, this.wave);

  final Vec3 at;

  /// Normalised distance from the centre, which is also this cage's place in
  /// the propagation: 0 arrives first, 1 last.
  final double wave;
}

/// One of the 48 nodes. Thirty-five of them are also a cell in the week and
/// carry [col], [row] and the timings that go with that; the other thirteen
/// only exist in the crystal and bud off the nearest settled block.
class LaunchNode {
  LaunchNode({required this.cage, required this.index, required this.to});

  final int cage;
  final int index;
  final Vec3 to;

  late Vec3 from;
  late double delay;
  late LaunchMark mark;

  int? col;
  int? row;
  double buildDelay = 0;
  double flipDelay = 0;
  bool marked = false;

  bool get isCell => col != null;
}

/// Timeline, in milliseconds from zero. The prototype at
/// `Documents/Apps/Zeolite/launch-sequence-prototype.html` is the spec these
/// come from; where the two disagree it is right and this is wrong.
class LaunchTiming {
  static const double markStart = 750;
  static const double foldStart = 1950;
  static const double foldEnd = 3900;
  static const double fieldStart = 3300;
  static const double fieldEnd = 5700;
  static const double wordStart = 3850;
  static const double sweepEnd = 4550;
  static const double wordEnd = 4850;
  static const double mainEnd = 4850;

  /// The short setting is the same painter with the week skipped, so it needs
  /// its own handful of numbers rather than its own animation.
  static const double shortEnd = 900;
  static const double shortFieldStart = 60;
  static const double shortFieldEnd = 820;

  static const double welcomeHandoff = 1100;
  static const double todayHandoff = 650;
}

class LaunchGeometry {
  /// A sodalite cage: every permutation of (0, ±1, ±2), which is a truncated
  /// octahedron and the unit zeolite A is actually built from. Bonds are the
  /// vertex pairs a distance √2 apart, found rather than listed by hand.
  static final List<Vec3> cageVerts = _buildVerts();
  static final List<List<int>> cageEdges = _buildEdges(cageVerts);

  static const List<Vec3> pair = <Vec3>[
    Vec3(-2.4, -1.3, 0),
    Vec3(2.4, 1.3, 0),
  ];

  /// The framework's own lattice vectors. [pair]'s second cage is the first
  /// plus [a], so the two the week becomes are already two points of one
  /// lattice and every other cage is `pair[0] + i·a + j·b`.
  static const Vec3 a = Vec3(4.8, 2.6, 0);
  static const Vec3 b = Vec3(2.6, -4.8, 0);

  /// Four shells out is where it stops paying: beyond this a cage is off
  /// screen at both eye distances for most of the rotation and still costs
  /// sixty draws a frame.
  static const double latticeSpan = 11.3;

  static const double tilt = 0.42;
  static const double spin = 0.5;
  static const double spinRamp = 1.6;
  static const double scale = 42;

  /// Eye distance. The launch screen sits close to two cages; the welcome
  /// screen pulls back to take in the whole lattice, which flattens the
  /// perspective the way stepping back from anything does.
  static const double near = 14;
  static const double far = 34;

  static const int cols = 7;
  static const int rows = 5;
  static const double cell = 30;
  static const double gap = 8;
  static const double pitch = (cell + gap) / scale;
  static const double maxDelay = 0.42;

  /// Each cage starts at `wave × fieldSpread` of the growth window and has the
  /// rest of it to arrive, so the inner shells land under the wordmark and the
  /// outer two while the camera is pulling back.
  static const double fieldSpread = 0.7;

  /// The field's strength on the splash, rising to 1 across the hand-off. It
  /// runs under full because the crystal has to stay the subject that close
  /// in — the field is the same accent colour and only the attendance-coloured
  /// nodes separate the two.
  static const double fieldLaunch = 0.6;

  static final List<LaunchCage> extension = _buildExtension();
  static final List<LaunchNode> nodes = _buildNodes();

  static Vec3 gridPoint(int col, int row) => Vec3(
        (col - (cols - 1) / 2) * pitch,
        (row - (rows - 1) / 2) * pitch,
        0,
      );

  /// Constant acceleration into a constant rate: the value and its slope are
  /// both continuous, so the crystal picks up speed instead of snapping into
  /// a spin.
  static double spinAt(double t, double from) {
    final double dt = math.max(0, t - from) / 1000;
    return dt < spinRamp
        ? spin * dt * dt / (2 * spinRamp)
        : spin * (dt - spinRamp / 2);
  }

  static Projected project(
    Vec3 v,
    double rotY,
    double tiltAngle,
    double scaleFactor,
    double cx,
    double cy,
    double dist,
  ) {
    final double cs = math.cos(rotY), sn = math.sin(rotY);
    final double x1 = v.x * cs - v.z * sn;
    final double z1 = v.x * sn + v.z * cs;
    final double ct = math.cos(tiltAngle), st = math.sin(tiltAngle);
    final double y2 = v.y * ct - z1 * st;
    final double z2 = v.y * st + z1 * ct;
    final double persp = dist / math.max(dist + z2, dist * 0.35);
    return Projected(
      cx + x1 * scaleFactor * persp,
      cy + y2 * scaleFactor * persp,
      z2,
      persp,
    );
  }

  /// Depth only reads as depth up to a point. The welcome screen's cues were
  /// tuned at eye distance 34, where perspective barely varies; at the
  /// splash's 14 a cage swinging towards the eye came out five pixels thick
  /// and lit brighter than the crystal it sits behind. This caps the cue, not
  /// the position, so the cages still register exactly on the lattice.
  static double depthCue(double p) => math.min(p, 1.15);

  static List<Vec3> _buildVerts() {
    final List<Vec3> verts = <Vec3>[];
    for (int zero = 0; zero < 3; zero++) {
      for (final bool swap in <bool>[false, true]) {
        for (final int s1 in <int>[-1, 1]) {
          for (final int s2 in <int>[-1, 1]) {
            final List<double> v = <double>[0, 0, 0];
            final List<int> rest =
                <int>[0, 1, 2].where((int i) => i != zero).toList();
            final int i = swap ? rest[1] : rest[0];
            final int j = swap ? rest[0] : rest[1];
            v[i] = s1.toDouble();
            v[j] = s2 * 2.0;
            verts.add(Vec3(v[0], v[1], v[2]));
          }
        }
      }
    }
    return verts;
  }

  static List<List<int>> _buildEdges(List<Vec3> verts) {
    final List<List<int>> edges = <List<int>>[];
    for (int i = 0; i < verts.length; i++) {
      for (int j = i + 1; j < verts.length; j++) {
        final double dx = verts[i].x - verts[j].x;
        final double dy = verts[i].y - verts[j].y;
        final double dz = verts[i].z - verts[j].z;
        if ((dx * dx + dy * dy + dz * dz - 2).abs() < 0.001) {
          edges.add(<int>[i, j]);
        }
      }
    }
    return edges;
  }

  static List<LaunchCage> _buildExtension() {
    final List<Vec3> offsets = <Vec3>[];
    final List<double> distances = <double>[];
    for (int i = -2; i <= 3; i++) {
      for (int j = -2; j <= 2; j++) {
        if (j == 0 && (i == 0 || i == 1)) continue;
        final Vec3 at = Vec3(
          pair[0].x + a.x * i + b.x * j,
          pair[0].y + a.y * i + b.y * j,
          0,
        );
        final double d = at.planarLength;
        if (d > latticeSpan) continue;
        offsets.add(at);
        distances.add(d);
      }
    }
    final double nearest = distances.reduce(math.min);
    final double furthest = distances.reduce(math.max);
    final List<LaunchCage> cages = <LaunchCage>[
      for (int i = 0; i < offsets.length; i++)
        LaunchCage(
          offsets[i],
          (distances[i] - nearest) / (furthest - nearest),
        ),
    ];
    cages.sort((LaunchCage x, LaunchCage y) => x.wave.compareTo(y.wave));
    return cages;
  }

  static List<LaunchNode> _buildNodes() {
    final List<LaunchNode> nodes = <LaunchNode>[];
    for (int cage = 0; cage < pair.length; cage++) {
      for (int i = 0; i < cageVerts.length; i++) {
        nodes.add(
          LaunchNode(cage: cage, index: i, to: cageVerts[i] + pair[cage]),
        );
      }
    }

    // Each cell takes the nearest free node in the plane, so no block crosses
    // the field to reach its place. Greedy and computed once, which is what
    // makes the fold read as a redistribution rather than a shuffle.
    final Set<int> taken = <int>{};
    final List<LaunchNode> cells = <LaunchNode>[];
    final double corner = math.max(gridPoint(0, 0).planarLength, 1);

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final Vec3 g = gridPoint(col, row);
        int best = -1;
        double bestD = double.infinity;
        for (int i = 0; i < nodes.length; i++) {
          if (taken.contains(i)) continue;
          final double dx = nodes[i].to.x - g.x;
          final double dy = nodes[i].to.y - g.y;
          final double d = dx * dx + dy * dy;
          if (d < bestD) {
            bestD = d;
            best = i;
          }
        }
        taken.add(best);

        final LaunchNode node = nodes[best];
        final double roll = hash(col * 5 + 1, row * 11 + 3);
        node
          ..col = col
          ..row = row
          ..from = g
          // The fold runs as a wave out of the centre of the week, spread wide
          // enough that the outer blocks are still travelling when the first
          // bonds form.
          ..delay = g.planarLength / corner * maxDelay
          ..buildDelay = (col + row) * 50 + hash(col, row) * 48
          ..marked = hash(col * 7, row * 13) > 0.18
          ..mark = roll > 0.30
              ? LaunchMark.present
              : (roll > 0.12 ? LaunchMark.absent : LaunchMark.cancelled)
          ..flipDelay = LaunchTiming.markStart +
              col * 95 +
              row * 44 +
              hash(row, col) * 65;
        cells.add(node);
      }
    }

    // The rest leave from whichever block is nearest, just after it settles.
    for (int i = 0; i < nodes.length; i++) {
      final LaunchNode n = nodes[i];
      if (n.isCell) continue;
      LaunchNode host = cells.first;
      double bestD = double.infinity;
      for (final LaunchNode c in cells) {
        final double dx = c.to.x - n.to.x;
        final double dy = c.to.y - n.to.y;
        final double d = dx * dx + dy * dy;
        if (d < bestD) {
          bestD = d;
          host = c;
        }
      }
      final double roll = hash(n.cage * 13 + n.index, i * 3);
      n
        ..from = host.from
        ..delay = math.min(host.delay + 0.12, maxDelay)
        ..mark = roll > 0.34
            ? LaunchMark.present
            : (roll > 0.14 ? LaunchMark.absent : LaunchMark.cancelled);
    }

    return nodes;
  }
}
