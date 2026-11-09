import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Puts a finger down on [slider] and drags it [dx] in two moves, leaving the
/// finger down so the thumb can be checked mid-drag. Returns the gesture and
/// the finger's x.
Future<(TestGesture, double)> dragSlider(
  WidgetTester tester,
  Finder slider,
  double dx,
) async {
  await tester.ensureVisible(slider);
  await tester.pumpAndSettle();
  final Offset start = tester.getCenter(slider);
  final TestGesture drag = await tester.startGesture(start);
  await tester.pump();
  await drag.moveBy(Offset(dx / 2, 0));
  await tester.pump();
  await drag.moveBy(Offset(dx / 2, 0));
  // One frame, no time: whatever the thumb does here is what the eye sees
  // under a moving finger.
  await tester.pump();
  return (drag, start.dx + dx);
}

/// The thumb is under the finger, give or take half a step, and no value
/// bubble is drawn over what sits above the slider.
void expectThumbUnderFinger(
  WidgetTester tester,
  Finder slider,
  double fingerX, {
  required int steps,
}) {
  final double left = tester.getTopLeft(slider).dx;
  final double tolerance = tester.getSize(slider).width / steps / 2 + 1.5;
  expect(
    slider,
    paints
      ..something((Symbol method, List<dynamic> arguments) =>
          method == #drawCircle &&
          // Tick marks are circles too, a pixel or two across.
          (arguments[1] as double) >= 6 &&
          ((arguments[0] as Offset).dx - (fingerX - left)).abs() <= tolerance),
    reason: 'the thumb should be drawn under the finger at x=$fingerX',
  );
  expect(tester.widget<Slider>(slider).label, isNull,
      reason: 'a label draws a value bubble over the text above the slider');
}

/// The x of the thumb's centre, in [slider]'s own coordinates.
double thumbX(WidgetTester tester, Finder slider) {
  double? x;
  expect(
    slider,
    paints
      ..something((Symbol method, List<dynamic> arguments) {
        if (method != #drawCircle || (arguments[1] as double) < 6) {
          return false;
        }
        x = (arguments[0] as Offset).dx;
        return true;
      }),
  );
  return x!;
}

/// Drags [slider] by [dx], releases, and returns where the thumb came to rest.
Future<double> dragAndRelease(
  WidgetTester tester,
  Finder slider,
  double dx,
) async {
  await tester.ensureVisible(slider);
  await tester.pumpAndSettle();
  final TestGesture drag = await tester.startGesture(tester.getCenter(slider));
  await tester.pump();
  await drag.moveBy(Offset(dx, 0));
  await tester.pump();
  await drag.up();
  await tester.pumpAndSettle();
  return thumbX(tester, slider);
}

/// Checks that [at75] sits three-quarters along a 0-100 track, using where the
/// thumb rests at 1 and at 100 to find the track's ends.
void expectThreeQuarters(double at1, double at75, double at100) {
  final double perPoint = (at100 - at1) / 99;
  final double zero = at1 - perPoint;
  expect((at75 - zero) / (at100 - zero), closeTo(0.75, 0.005),
      reason: '75 should sit three-quarters along a track that starts at 0');
}

/// Fires one screen-reader increase or decrease at [slider].
void adjustBySemantics(
  WidgetTester tester,
  Finder slider,
  SemanticsAction action,
) {
  final SemanticsNode node = tester.getSemantics(slider);
  node.owner!.performAction(node.id, action);
}

/// How many nodes in the tree a screen reader could adjust.
int adjustableNodes(WidgetTester tester) {
  int count = 0;
  bool visit(SemanticsNode node) {
    final SemanticsData data = node.getSemanticsData();
    if (data.hasAction(SemanticsAction.increase) ||
        data.hasAction(SemanticsAction.decrease)) {
      count++;
    }
    node.visitChildren(visit);
    return true;
  }

  SemanticsNode root = tester.getSemantics(find.byType(Slider).first);
  while (root.parent != null) {
    root = root.parent!;
  }
  visit(root);
  return count;
}
