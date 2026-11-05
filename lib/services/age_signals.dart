import 'package:flutter/services.dart';

/// All Zeolite keeps of Play's age signal. Play's terms allow it only for an
/// age-appropriate experience, so nothing about it is logged or sent.
enum PlayAge { under18, adult, unverified, none }

/// Only a Play-installed build (or a licence tester's) gets a range, and only
/// where Play shares ages; anything else is [PlayAge.none].
class AgeSignals {
  const AgeSignals({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('zeolite/age_signals');

  final MethodChannel _channel;

  /// Play's sharing prompt can outlast this; that choice counts next start.
  static const Duration timeout = Duration(seconds: 10);

  Future<PlayAge> check() async {
    try {
      final Map<Object?, Object?>? reply = await _channel
          .invokeMapMethod<Object?, Object?>('check')
          .timeout(timeout);
      return derive(reply);
    } on Exception {
      // Not reported: a crash report is one more place the signal must not
      // reach.
      return PlayAge.none;
    }
  }

  /// Any range topping out below 18 is under 18, whatever the source tier or
  /// a custom range in Play Console. `change` is not read: nothing is held
  /// behind a significant-change approval yet.
  static PlayAge derive(Map<Object?, Object?>? reply) {
    if (reply == null) return PlayAge.none;
    switch (reply['status']) {
      case 'verification_required':
        return PlayAge.unverified;
      case 'shared':
        final Object? lower = reply['lower'];
        final Object? upper = reply['upper'];
        if (upper is int && upper < 18) return PlayAge.under18;
        if (upper == null && lower is int && lower >= 18) return PlayAge.adult;
        return PlayAge.none;
      default:
        return PlayAge.none;
    }
  }
}
