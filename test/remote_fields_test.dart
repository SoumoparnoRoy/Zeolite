import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/sync/remote_fields.dart';

void main() {
  test('a number that is not finite reads as absent', () {
    expect(readInt(double.nan), isNull);
    expect(readInt(double.infinity), isNull);
    expect(readDouble(double.nan), isNull);
    expect(readInt(2.6), 3);
  });

  test('a value of the wrong type reads as absent', () {
    expect(readString(5), isNull);
    expect(readInt(<Object?>[]), isNull);
    expect(readInt('12'), 12);
  });

  test('a day key must name a real day', () {
    expect(readDay(20260228), DateTime(2026, 2, 28));
    expect(readDay(20261301), isNull);
    expect(readDay(20260230), isNull);
    expect(readDay('20260228'), DateTime(2026, 2, 28));
  });

  test('a class time sits inside one day and ends after it starts', () {
    expect(isClassTime(540, 600), isTrue);
    expect(isClassTime(600, 540), isFalse);
    expect(isClassTime(-1, 60), isFalse);
    expect(isClassTime(1380, 1441), isFalse);
    expect(isClassTime(540, null), isFalse);
  });
}
