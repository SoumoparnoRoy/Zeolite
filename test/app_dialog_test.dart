import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
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
}
