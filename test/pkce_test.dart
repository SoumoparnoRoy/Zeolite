import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/notion/pkce.dart';

class _FixedRandom implements Random {
  int _step = 0;

  @override
  int nextInt(int max) => (_step++ * 7 + 3) % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

void main() {
  /// Verbatim from `server/src/routes.js`.
  final RegExp serverPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

  test('the challenge is what the service computes for the verifier', () {
    final PkcePair pair = PkcePair.generate(random: _FixedRandom());

    // Both produced by node's crypto, so hashing in Dart and comparing to Dart
    // would pass here while padded or standard base64 broke the handshake.
    expect(pair.verifier, 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw');
    expect(pair.challenge, 'Ucth0C-OcYdc4s8JT_o3Lll7KsfpNlpYmwObmzH89UA');
  });

  test('both halves satisfy the pattern the service enforces', () {
    final PkcePair pair = PkcePair.generate();

    expect(serverPattern.hasMatch(pair.challenge), isTrue);
    expect(serverPattern.hasMatch(pair.verifier), isTrue);
  });

  test('a real pair is different every time', () {
    final Set<String> verifiers = <String>{
      for (int i = 0; i < 20; i++) PkcePair.generate().verifier,
    };

    expect(verifiers, hasLength(20));
  });
}
