import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/time_picker.dart';
import 'package:zeolite/widgets/common.dart';

/// A page that is one big button, so whatever a dialog or sheet button sits
/// over, a tap that gets through lands on it and is counted.
Future<BuildContext> _page(WidgetTester tester, void Function() onTap) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext c) {
            context = c;
            return SizedBox.expand(
              child: TextButton(onPressed: onTap, child: const Text('behind')),
            );
          },
        ),
      ),
    ),
  );
  return context;
}

Future<void> _doubleTap(WidgetTester tester, Finder button) async {
  final Offset at = tester.getCenter(button);
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tapAt(at);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a double tap on a dialog button stops at the dialog',
      (WidgetTester tester) async {
    int behind = 0;
    final BuildContext context = await _page(tester, () => behind++);
    unawaited(showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        content: const Text('Sure?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    await _doubleTap(tester, find.text('OK'));
    expect(find.text('Sure?'), findsNothing);
    expect(behind, 0);

    await tester.tap(find.text('behind'));
    expect(behind, 1);
  });

  testWidgets('a double tap on a sheet button stops at the sheet',
      (WidgetTester tester) async {
    int behind = 0;
    final BuildContext context = await _page(tester, () => behind++);
    unawaited(showAppSheet<void>(
      context: context,
      title: 'Sheet',
      child: Builder(
        builder: (BuildContext context) => FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await _doubleTap(tester, find.text('Done'));
    expect(find.text('Sheet'), findsNothing);
    expect(behind, 0);

    await tester.tap(find.text('behind'));
    expect(behind, 1);
  });

  testWidgets('a sheet opened as another closes takes a tap once it is up',
      (WidgetTester tester) async {
    final BuildContext context = await _page(tester, () {});
    int second = 0;
    Future<void> chain() async {
      final bool? next = await showAppSheet<bool>(
        context: context,
        title: 'First',
        child: Builder(
          builder: (BuildContext context) => FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Next'),
          ),
        ),
      );
      if (next != true || !context.mounted) return;
      await showAppSheet<void>(
        context: context,
        title: 'Second',
        child: FilledButton(
          onPressed: () => second++,
          child: const Text('Count'),
        ),
      );
    }

    unawaited(chain());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);

    await tester.tap(find.text('Count'));
    expect(second, 1);
  });

  testWidgets('a double tap on a menu item stops at the menu',
      (WidgetTester tester) async {
    int behind = 0;
    final BuildContext context = await _page(tester, () => behind++);
    unawaited(showAppMenu<int>(
      context: context,
      items: const <PopupMenuEntry<int>>[
        PopupMenuItem<int>(value: 1, child: Text('Pick')),
      ],
    ));
    await tester.pumpAndSettle();

    await _doubleTap(tester, find.text('Pick'));
    expect(find.text('Pick'), findsNothing);
    expect(behind, 0);

    await tester.tap(find.text('behind'));
    expect(behind, 1);
  });

  testWidgets('a menu stays over its button when the screen changes size',
      (WidgetTester tester) async {
    addTearDown(tester.view.reset);
    late BuildContext anchor;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: const Alignment(-0.5, 0),
            child: Builder(
              builder: (BuildContext context) {
                anchor = context;
                return const SizedBox(width: 48, height: 48);
              },
            ),
          ),
        ),
      ),
    );
    unawaited(showAppMenu<int>(
      context: anchor,
      items: const <PopupMenuEntry<int>>[
        PopupMenuItem<int>(value: 1, child: Text('Pick')),
      ],
    ));
    await tester.pumpAndSettle();
    double gap() =>
        tester.getTopLeft(find.text('Pick')).dx -
        tester.getTopLeft(find.byType(SizedBox).first).dx;
    final double before = gap();

    tester.view.physicalSize = tester.view.physicalSize * 1.5;
    await tester.pumpAndSettle();
    expect(gap(), moreOrLessEquals(before));
  });

  testWidgets('a double tap on a date picker\'s OK stops at the picker',
      (WidgetTester tester) async {
    int behind = 0;
    final BuildContext context = await _page(tester, () => behind++);
    unawaited(showAppDatePicker(
      context: context,
      initialDate: DateTime(2026, 10, 31),
      firstDate: DateTime(2026),
      lastDate: DateTime(2027),
    ));
    await tester.pumpAndSettle();

    await _doubleTap(tester, find.text('OK'));
    expect(find.text('OK'), findsNothing);
    expect(behind, 0);

    await tester.tap(find.text('behind'));
    expect(behind, 1);
  });

  testWidgets('a double tap on a time picker\'s OK stops at the picker',
      (WidgetTester tester) async {
    int behind = 0;
    final BuildContext context = await _page(tester, () => behind++);
    unawaited(showAppTimePicker(
      context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
      use24Hour: false,
    ));
    await tester.pumpAndSettle();

    await _doubleTap(tester, find.text('OK'));
    expect(find.text('OK'), findsNothing);
    expect(behind, 0);

    await tester.tap(find.text('behind'));
    expect(behind, 1);
  });

  // No drag handle, as on the one-off and weekly sheets: the handle's own
  // height would push the title clear and hide the bug.
  testWidgets(
      'a sheet taller than the screen keeps its title below the '
      'status bar', (WidgetTester tester) async {
    tester.view.padding = const FakeViewPadding(top: 142);
    tester.view.viewPadding = const FakeViewPadding(top: 142);
    addTearDown(tester.view.reset);
    final BuildContext context = await _page(tester, () {});
    unawaited(showAppSheet<void>(
      context: context,
      title: 'Tall',
      enableDrag: false,
      child: const SizedBox(height: 2000),
    ));
    await tester.pumpAndSettle();

    final double statusBar = 142 / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(find.text('Tall')).dy,
        greaterThanOrEqualTo(statusBar));
  });
}
