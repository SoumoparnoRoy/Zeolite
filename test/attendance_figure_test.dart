import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/words.dart';

void main() {
  test('attendance is cut to two places, never rounded up to a target', () {
    expect(Words.attendance(74.996), '74.99%');
    expect(Words.attendance(200 / 3), '66.66%');
    expect(Words.attendance(75), '75.00%');
    expect(Words.attendance(100), '100.00%');
  });

  test('a whole figure stored a hair under itself still reads whole', () {
    expect(28.999999999999996, isNot(29));
    expect(Words.attendance(28.999999999999996), '29.00%');
  });

  test('targets and term progress stay whole', () {
    expect(Words.percent(75), '75%');
    expect(Words.percent(57.4), '57%');
  });
}
