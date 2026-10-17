import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/auth_service.dart';

class _Provider implements UserInfo {
  _Provider(this.providerId);

  @override
  final String providerId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Account implements User {
  _Account({required this.emailVerified, required String provider})
      : providerData = <UserInfo>[_Provider(provider)];

  @override
  final bool emailVerified;

  @override
  final List<UserInfo> providerData;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the codes that would otherwise read as a broken app are named', () {
    // Firebase refuses rather than linking these, which reads as a broken app.
    expect(
      AuthService.reasonFor('account-exists-with-different-credential'),
      AuthFailure.differentSignInMethod,
    );
    expect(
      AuthService.reasonFor('requires-recent-login'),
      AuthFailure.needsRecentLogin,
    );
    expect(
        AuthService.reasonFor('invalid-credential'), AuthFailure.wrongPassword);
    expect(
        AuthService.reasonFor('network-request-failed'), AuthFailure.network);
    expect(AuthService.reasonFor('user-mismatch'), AuthFailure.wrongAccount);
    expect(AuthService.reasonFor('something-new'), AuthFailure.unknown);
  });

  // Anyone can sign up with anyone's address; only the link proves it.
  test('only a password account that has not opened its link waits', () {
    expect(
      AuthService.needsVerification(
          _Account(emailVerified: false, provider: 'password')),
      isTrue,
    );
    expect(
      AuthService.needsVerification(
          _Account(emailVerified: true, provider: 'password')),
      isFalse,
    );
    expect(
      AuthService.needsVerification(
          _Account(emailVerified: false, provider: 'google.com')),
      isFalse,
    );
  });
}
