import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/app.dart';

String? _screenFor(String? payload) {
  final int? tab = RootShell.tabForPayload(payload);
  return tab == null ? null : RootShell.tabNames[tab];
}

void main() {
  group('a tapped notification', () {
    test('opens the screen that answers it', () {
      expect(_screenFor('danger'), 'stats');
      expect(_screenFor('evening'), 'today');
      expect(_screenFor('class:2026-08-19|1'), 'today');
    });

    test('leaves the app where it is when the payload means nothing', () {
      // A payload in the tray outlives the build that wrote it.
      expect(RootShell.tabForPayload(null), isNull);
      expect(RootShell.tabForPayload('danger:7'), isNull);
      expect(RootShell.tabForPayload(''), isNull);
    });
  });
}
