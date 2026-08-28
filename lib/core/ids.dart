import 'dart:math';

final Random _random = Random.secure();

/// An identifier that means the same thing on every device, which
/// `subjects.id` cannot be — it is an autoincrement, so two installs number the
/// same course differently.
String newId() {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < 16; i++) {
    out.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
