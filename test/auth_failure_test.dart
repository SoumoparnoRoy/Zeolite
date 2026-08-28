import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/auth_service.dart';

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
    expect(AuthService.reasonFor('invalid-credential'),
        AuthFailure.wrongPassword);
    expect(AuthService.reasonFor('network-request-failed'),
        AuthFailure.network);
    expect(AuthService.reasonFor('something-new'), AuthFailure.unknown);
  });
}
