import '../../core/date_utils.dart';

/// Reading what a pull brings back. The account is only as well-formed as the
/// oldest or newest app that wrote to it, so a value of the wrong type reads
/// as absent here rather than throwing and ending the run for every row.

int? readInt(Object? value) => switch (value) {
      int v => v,
      // NaN and infinity are storable in Firestore and `round` throws on them.
      double v when v.isFinite => v.round(),
      String v => int.tryParse(v),
      _ => null,
    };

double? readDouble(Object? value) => switch (value) {
      num v when v.isFinite => v.toDouble(),
      String v => double.tryParse(v),
      _ => null,
    };

String? readString(Object? value) => value is String ? value : null;

/// A day key, or null when it is not one. `Dates.fromKey` rolls month 13 into
/// the next January without complaint, so the round trip is the test.
DateTime? readDay(Object? value) {
  final int? key = readInt(value);
  if (key == null) return null;
  final DateTime day = Dates.fromKey(key);
  return Dates.keyOf(day) == key ? day : null;
}

bool isMinuteOfDay(int? minute) =>
    minute != null && minute >= 0 && minute < Clock.minutesPerDay;

bool isClassTime(int? start, int? end) =>
    isMinuteOfDay(start) &&
    end != null &&
    end > start! &&
    end <= Clock.minutesPerDay;

/// Thrown for a pulled row that cannot be turned into a local one. The
/// coordinator catches it row by row, so one bad document costs only itself.
class UnreadableRow implements Exception {
  const UnreadableRow(this.localKey);

  final String localKey;

  @override
  String toString() => 'UnreadableRow($localKey)';
}
