import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/features/launch/launch_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the crystal', () {
    test('is a sodalite cage: 24 vertices and 36 bonds', () {
      expect(LaunchGeometry.cageVerts, hasLength(24));
      expect(LaunchGeometry.cageEdges, hasLength(36));
    });

    test('every node is either a day of the week or buds off one', () {
      final List<LaunchNode> nodes = LaunchGeometry.nodes;
      expect(nodes, hasLength(48));
      expect(nodes.where((LaunchNode n) => n.isCell), hasLength(35));

      // Each cell takes a node of its own, or two blocks would fly to the
      // same place and one would be left with nothing to become.
      final Set<String> places = nodes
          .where((LaunchNode n) => n.isCell)
          .map((LaunchNode n) => '${n.cage}:${n.index}')
          .toSet();
      expect(places, hasLength(35));
    });

    test('there is no seam: the fold starts on the flat week it draws', () {
      // The whole act reads as one transformation only because the first
      // frame of the fold is pixel-identical to the last frame of the week.
      for (final LaunchNode n in LaunchGeometry.nodes) {
        if (!n.isCell) continue;
        final Projected p = LaunchGeometry.project(
            n.from, 0, 0, LaunchGeometry.scale, 170, 350, LaunchGeometry.near);
        final double x = 170 +
            (n.col! - (LaunchGeometry.cols - 1) / 2) *
                (LaunchGeometry.cell + LaunchGeometry.gap);
        final double y = 350 +
            (n.row! - (LaunchGeometry.rows - 1) / 2) *
                (LaunchGeometry.cell + LaunchGeometry.gap);
        expect(p.x, closeTo(x, 0.001), reason: 'col ${n.col}');
        expect(p.y, closeTo(y, 0.001), reason: 'row ${n.row}');
        expect(p.persp, closeTo(1, 0.001));
      }
    });
  });

  group('the field', () {
    test('is fourteen cages in four shells, all on the framework lattice', () {
      expect(LaunchGeometry.extension, hasLength(14));

      final Set<String> shells = <String>{};
      for (final LaunchCage cage in LaunchGeometry.extension) {
        shells.add(cage.wave.toStringAsFixed(2));

        // Solving pair[0] + i·a + j·b for the cage's offset has to come back
        // whole, or that cage is decoration rather than more of the crystal.
        final double dx = cage.at.x - LaunchGeometry.pair[0].x;
        final double dy = cage.at.y - LaunchGeometry.pair[0].y;
        final double det = LaunchGeometry.a.x * LaunchGeometry.b.y -
            LaunchGeometry.a.y * LaunchGeometry.b.x;
        final double i =
            (dx * LaunchGeometry.b.y - dy * LaunchGeometry.b.x) / det;
        final double j =
            (LaunchGeometry.a.x * dy - LaunchGeometry.a.y * dx) / det;
        expect(i, closeTo(i.roundToDouble(), 0.001));
        expect(j, closeTo(j.roundToDouble(), 0.001));
      }
      expect(shells, hasLength(4));
    });

    test('grows outward, and only after the crystal has settled', () {
      double alphaAt(LaunchCage cage, double clock) {
        final double grown =
            seg(clock, LaunchTiming.fieldStart, LaunchTiming.fieldEnd);
        return easeOut(clampd(
          (grown - cage.wave * LaunchGeometry.fieldSpread) /
              (1 - LaunchGeometry.fieldSpread),
          0,
          1,
        ));
      }

      final LaunchCage inner = LaunchGeometry.extension.first;
      final LaunchCage outer = LaunchGeometry.extension.last;

      // Nothing of the field exists while the week is still folding.
      expect(alphaAt(outer, LaunchTiming.fieldStart), 0);
      expect(alphaAt(inner, LaunchTiming.fieldStart), 0);

      // The inner shell arrives under the wordmark, the outer one only while
      // the camera is pulling back — one propagation across both acts.
      expect(alphaAt(inner, LaunchTiming.wordEnd), 1);
      expect(alphaAt(outer, LaunchTiming.wordEnd), lessThan(1));
      expect(alphaAt(outer, LaunchTiming.fieldEnd), 1);
    });
  });

  group('the settings it reads', () {
    test('default to the full sequence and an unanswered welcome screen', () {
      const AppSettings settings = AppSettings();
      expect(settings.launchAnimation, LaunchAnimation.full);
      expect(settings.welcomeShown, isFalse);
    });

    test('both survive a restart', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final SettingsService service = SettingsService();

      await service.save((await service.load()).copyWith(
        launchAnimation: LaunchAnimation.short,
        welcomeShown: true,
      ));

      final AppSettings restored = await service.load();
      expect(restored.launchAnimation, LaunchAnimation.short);
      expect(restored.welcomeShown, isTrue);
    });

    test('updating an install that has already onboarded does not re-ask',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      // The store as a build that never knew the key would have left it.
      await SharedPreferencesAsync().setBool('ut.onboarded', true);

      expect((await SettingsService().load()).welcomeShown, isTrue);
    });

    test('a value written by a newer build reads back as the default', () {
      expect(LaunchAnimation.fromName('cinematic'), LaunchAnimation.full);
      expect(LaunchAnimation.fromName(null), LaunchAnimation.full);
    });

    test('quitting part way through setup does not re-ask the choice', () {
      // `welcomeShown` is written when the welcome screen is answered and
      // `onboarded` only when setup finishes, so the gap between them is a
      // real state the app has to come back to correctly.
      const AppSettings midway = AppSettings(welcomeShown: true);
      expect(midway.onboarded, isFalse);
      expect(midway.welcomeShown, isTrue);
    });
  });
}
