import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What a stop points at. Each one is on screen in a fresh install with no
/// classes, so the tour never needs sample data to have something to show.
/// [addClassFab] has its own key: a FAB shrinking away after the last class is
/// deleted is still on screen when the empty state's button arrives.
enum TourTarget {
  addClass,
  addClassFab,
  weekStrip,
  timetableTab,
  statsTab,
  settingsTab,
}

/// The widgets the tour highlights, found by key so the tour measures where
/// they really are rather than where a layout is expected to put them.
class TourTargets {
  final Map<TourTarget, GlobalKey> _keys = <TourTarget, GlobalKey>{
    for (final TourTarget t in TourTarget.values)
      t: GlobalKey(debugLabel: 'tour ${t.name}'),
  };

  GlobalKey keyFor(TourTarget target) => _keys[target]!;
}

final tourTargetsProvider = Provider<TourTargets>((ref) => TourTargets());

/// Bumped by Settings › Show tour again. [TourLauncher] around the shell
/// listens, since only the shell can bring Today to the front first.
class TourReplay extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final tourReplayProvider = NotifierProvider<TourReplay, int>(TourReplay.new);

class TourStop {
  const TourStop({
    required this.target,
    required this.title,
    required this.body,
    this.orTarget,
    this.gap = 4,
    this.radius,
    this.maxWidth,
  });

  final TourTarget target;

  /// Where the stop points when [target] isn't on screen.
  final TourTarget? orTarget;
  final String title;
  final String body;

  /// Space between the target and the highlight's edge; negative pulls it in
  /// from a tab's full cell to the part that reads as the tab.
  final double gap;

  /// Null follows the target's own pill shape.
  final double? radius;

  /// A tab's cell spans a quarter of the screen, which on a tablet is far
  /// wider than the tab reads; the highlight keeps to its middle.
  final double? maxWidth;
}

/// Worded like the store listing and Help and FAQ.
const List<TourStop> tourStops = <TourStop>[
  TourStop(
    target: TourTarget.addClass,
    orTarget: TourTarget.addClassFab,
    title: 'Start with your classes',
    body: 'Add each weekly class once. On its day it shows up here with '
        'Present, Absent and Cancelled, so marking takes one tap.',
  ),
  TourStop(
    target: TourTarget.weekStrip,
    title: 'Pick a day',
    body: 'Tap a day, or swipe across, to see its classes. The grid button '
        'shows the whole week at once.',
    gap: 6,
    radius: 22,
  ),
  TourStop(
    target: TourTarget.timetableTab,
    title: 'Your week',
    body: 'Weekly classes and one-off ones, laid out week by week. Press and '
        'hold a class to change it.',
    gap: -3,
    radius: 18,
    maxWidth: 104,
  ),
  TourStop(
    target: TourTarget.statsTab,
    title: 'Where you stand',
    body: 'Your percentage for each subject and overall, how many classes you '
        'can skip, and how many you need to attend to get back on target.',
    gap: -3,
    radius: 18,
    maxWidth: 104,
  ),
  TourStop(
    target: TourTarget.settingsTab,
    title: 'Bring it in, keep it safe',
    body: 'Import a timetable from pasted text or a photo, under Add from a '
        'file. Backups, sign-in and Help and FAQ are here too, and so is '
        'this tour.',
    gap: -3,
    radius: 18,
    maxWidth: 104,
  ),
];
