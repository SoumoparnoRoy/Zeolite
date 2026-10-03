import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/time_picker.dart';

/// Opens the picker under a device that claims the opposite clock convention,
/// so the only thing that can decide the format is the setting we pass in.
Future<void> _open(
  WidgetTester tester, {
  required bool device24Hour,
  required bool app24Hour,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        alwaysUse24HourFormat: device24Hour,
        textScaler: textScaler,
      ),
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showAppTimePicker(
              context,
              initialTime: const TimeOfDay(hour: 9, minute: 0),
              use24Hour: app24Hour,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('12-hour setting keeps the am/pm toggle on a 24-hour device',
      (WidgetTester tester) async {
    await _open(tester, device24Hour: true, app24Hour: false);

    expect(find.text('AM'), findsOneWidget);
    expect(find.text('PM'), findsOneWidget);
  });

  testWidgets('24-hour setting drops it on a 12-hour device',
      (WidgetTester tester) async {
    await _open(tester, device24Hour: false, app24Hour: true);

    expect(find.text('AM'), findsNothing);
    expect(find.text('PM'), findsNothing);
  });

  testWidgets('the dialog does not ride the tablet scale ramp',
      (WidgetTester tester) async {
    // The dialog lays out at fixed dimensions, so the ramp only grows the text
    // inside it.
    const TextScaler viewer = TextScaler.linear(1.2);
    await _open(
      tester,
      device24Hour: false,
      app24Hour: true,
      textScaler: const ScaledText(viewer, 1.3),
    );

    // The viewer's own scaling survives; only our factor is taken off.
    expect(
      MediaQuery.textScalerOf(tester.element(find.text('Cancel'))),
      viewer,
    );
  });

  testWidgets('a viewer scaler that never rode the ramp is left alone',
      (WidgetTester tester) async {
    const TextScaler viewer = TextScaler.linear(1.4);
    await _open(
      tester,
      device24Hour: false,
      app24Hour: false,
      textScaler: viewer,
    );

    expect(
      MediaQuery.textScalerOf(tester.element(find.text('Cancel'))),
      viewer,
    );
  });

  testWidgets('it opens on the keyboard, not the clock face',
      (WidgetTester tester) async {
    // The 24-hour dial cannot be spaced properly from outside the framework,
    // so the default path avoids it. The dial is still reachable from here.
    await _open(tester, device24Hour: true, app24Hour: true);

    expect(find.byType(TextField), findsNWidgets(2));
  });
}
