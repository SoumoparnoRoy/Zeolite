import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// Loading before it is null, because Firebase restores a session
/// asynchronously and reading that gap as signed out flashes the wrong screen
/// on every launch.
final signedInUserProvider = StreamProvider<User?>(
  (ref) => ref.watch(authServiceProvider).changes,
);

/// True while a password account has not opened its verification link. Sync
/// stays off until it has: the rules refuse its writes, and a refused write
/// would read as a sign-in problem. Everything on the device works meanwhile.
final verificationPendingProvider =
    NotifierProvider<VerificationPending, bool>(VerificationPending.new);

class VerificationPending extends Notifier<bool> {
  @override
  bool build() {
    final User? user = ref.watch(signedInUserProvider).value;
    return user != null && AuthService.needsVerification(user);
  }

  /// The sign-in stream says nothing when the link is opened elsewhere, so
  /// this is how the app finds out.
  Future<bool> recheck() async {
    final bool verified = await ref.read(authServiceProvider).confirmVerified();
    if (verified) state = false;
    return verified;
  }
}
