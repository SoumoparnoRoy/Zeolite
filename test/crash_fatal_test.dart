import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/main.dart';

void main() {
  test('only an error nothing caught is a crash', () {
    expect(crashIsFatal('uncaught'), isTrue);
    expect(crashIsFatal('Flutter framework'), isFalse);
    expect(crashIsFatal('home widget update'), isFalse);
  });
}
