import 'package:flutter/material.dart';

import 'app_theme.dart';

/// [showTimePicker], but honouring the app's own 12/24-hour preference, and
/// opening on the keyboard rather than the clock face.
///
/// The Material picker takes `alwaysUse24HourFormat` from the device, so on a
/// 24-hour phone it opens a 24-hour dial while every label the app draws
/// through `Clock.format` still reads `9:00 AM`. Overriding the MediaQuery flag
/// is the only hook the picker offers, and the same override is where the
/// tablet scale ramp gets taken back off.
///
/// It opens in [TimePickerEntryMode.input] because the 24-hour dial cannot be
/// made to read cleanly: the inner ring sits a fixed 28dp inside the outer one
/// and the selector has a 24dp radius, so selecting an hour puts the disc on
/// top of the number twelve hours away. Both constants are private to the
/// framework and `TimePickerThemeData` exposes no geometry, so there is nothing
/// to tune. Typing a class time is quicker than dragging to the minute anyway,
/// and the dial is still one tap away behind the keyboard icon.
Future<TimeOfDay?> showAppTimePicker(
  BuildContext context, {
  required TimeOfDay initialTime,
  required bool use24Hour,
  String? helpText,
}) {
  return showTimePicker(
    context: context,
    initialTime: initialTime,
    helpText: helpText,
    initialEntryMode: TimePickerEntryMode.input,
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData mq = MediaQuery.of(context);
      final TextScaler scaler = mq.textScaler;
      return MediaQuery(
        data: mq.copyWith(
          alwaysUse24HourFormat: use24Hour,
          // The dialog sizes its own fields and dial at fixed dimensions, so
          // the tablet ramp grows text inside geometry that does not move. The
          // ramp is for our 320dp artboard, which this dialog is not part of —
          // but the viewer's own scaling still has to apply.
          textScaler: scaler is ScaledText ? scaler.inner : scaler,
        ),
        child: child!,
      );
    },
  );
}
