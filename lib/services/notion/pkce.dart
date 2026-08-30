import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// The two halves of the connect handshake. Any app can register the
/// `zeolite://` scheme and intercept the redirect, so the session id it
/// carries is assumed public; what makes it useless to an interceptor is that
/// [verifier] never leaves the device while [challenge] does.
@immutable
class PkcePair {
  const PkcePair({required this.verifier, required this.challenge});

  factory PkcePair.generate({Random? random}) {
    final Random source = random ?? Random.secure();
    final List<int> bytes =
        List<int>.generate(_verifierBytes, (_) => source.nextInt(256));
    final String verifier = _base64Url(bytes);
    return PkcePair(
      verifier: verifier,
      challenge: _base64Url(sha256.convert(utf8.encode(verifier)).bytes),
    );
  }

  final String verifier;
  final String challenge;
}

/// 32 bytes is exactly 43 unpadded characters, which is both RFC 7636's
/// shortest verifier and the only length `server/`'s `CHALLENGE_PATTERN`
/// accepts. Changing it fails `/start` with a bare 400.
const int _verifierBytes = 32;

/// Unpadded, matching node's `digest("base64url")` byte for byte.
String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');
