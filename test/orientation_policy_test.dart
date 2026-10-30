import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/orientation_policy.dart';

void main() {
  const List<DeviceOrientation> portrait = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  test('a phone stays portrait, up to just under 600dp', () {
    expect(orientationsFor(360), portrait);
    expect(orientationsFor(599.9), portrait);
  });

  test('from 600dp the display turns all four ways', () {
    expect(orientationsFor(600), DeviceOrientation.values);
    expect(orientationsFor(776), DeviceOrientation.values);
  });
}
