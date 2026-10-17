import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/report_error.dart';
import 'firebase/firestore_sync_target.dart';

/// Why a sign-in did not go through, in terms the screen can phrase.
enum AuthFailure {
  network,
  wrongPassword,
  noSuchUser,
  emailInUse,
  weakPassword,
  invalidEmail,

  /// The address already has an account made a different way — almost always
  /// signing up with a password and later tapping Google, or the reverse.
  /// Firebase refuses rather than linking, and an unhandled refusal reads as a
  /// broken login.
  differentSignInMethod,

  /// Deleting an account needs a recent sign-in, and Firebase decides what
  /// recent means. The screen asks them to sign in again and retry.
  needsRecentLogin,

  /// Confirming with Google picked a different account from the one signed in.
  wrongAccount,

  cancelled,
  unknown,
}

@immutable
class AuthResult {
  const AuthResult.ok()
      : failure = null,
        message = null;
  const AuthResult.failed(this.failure, {this.message});

  final AuthFailure? failure;
  final String? message;

  bool get ok => failure == null;
}

/// Sign-in, and the account deletion Play requires of any app with accounts.
class AuthService {
  AuthService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  Stream<User?> get changes => _auth.authStateChanges();
  User? get user => _auth.currentUser;

  /// The link is what proves the address belongs to whoever typed it. Without
  /// it, anyone could sign up with someone else's Gmail address, fill the
  /// account, and have Google hand it to the owner on their first sign-in.
  Future<AuthResult> signUp(String email, String password) => _guard(() async {
        final UserCredential credential =
            await _auth.createUserWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        // Not waited on: the account exists either way, and the Account
        // screen offers to send the link again.
        final User? user = credential.user;
        if (user != null) {
          unawaited(user.sendEmailVerification().catchError(
                (Object error, StackTrace stack) =>
                    reportError(error, stack, where: 'verification email'),
              ));
        }
      });

  Future<AuthResult> sendVerification() =>
      _guard(() async => _auth.currentUser?.sendEmailVerification());

  /// Firebase answers the same whether or not the address has an account, so
  /// the screen can't say which, and shouldn't.
  Future<AuthResult> sendPasswordReset(String email) =>
      _guard(() => _auth.sendPasswordResetEmail(email: email.trim()));

  /// A password account that has not opened its link. Google vouches for its
  /// own addresses, so only the password provider is ever unverified here.
  static bool needsVerification(User user) =>
      !user.emailVerified &&
      user.providerData.any((UserInfo info) => info.providerId == 'password');

  /// Asks Firebase again after the link was opened in the mail app. The ID
  /// token is refreshed too: the rules read `email_verified` from the token,
  /// and the one this device holds was minted before the click.
  Future<bool> confirmVerified() async {
    try {
      await _auth.currentUser?.reload();
      final User? user = _auth.currentUser;
      if (user == null || !user.emailVerified) return false;
      await user.getIdToken(true);
      return true;
    } on FirebaseAuthException {
      return false;
    } catch (error, stack) {
      reportError(error, stack, where: 'verification check');
      return false;
    }
  }

  Future<AuthResult> signIn(String email, String password) =>
      _guard(() => _auth.signInWithEmailAndPassword(
            email: email.trim(),
            password: password,
          ));

  /// google_sign_in 7 is Credential Manager backed: [initialize] once, then
  /// [authenticate] for the account picker, then scopes for the access token
  /// Firebase needs alongside the id token.
  Future<AuthResult> signInWithGoogle() async {
    return _guard(() async {
      await GoogleSignIn.instance.initialize();
      final GoogleSignInAccount account =
          await GoogleSignIn.instance.authenticate();
      final GoogleSignInClientAuthorization authorization = await account
          .authorizationClient
          .authorizeScopes(<String>['email', 'profile']);

      await _auth.signInWithCredential(
        GoogleAuthProvider.credential(
          idToken: account.authentication.idToken,
          accessToken: authorization.accessToken,
        ),
      );
    });
  }

  /// Firebase first: that is the sign-out that matters, and a Google SDK that
  /// throws must not leave the account signed in behind it.
  Future<void> signOut() async {
    await _auth.signOut();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (error, stack) {
      reportError(error, stack, where: 'Google sign-out');
    }
  }

  /// Which way [user] proves it is them before a delete.
  static bool confirmsWithGoogle(User user) =>
      user.providerData.any((UserInfo info) => info.providerId == 'google.com');

  /// Firebase refuses to delete an account whose sign-in is more than a few
  /// minutes old, and checks only at the last step, after the data has gone.
  /// Confirming first makes the delete one step instead of two.
  Future<AuthResult> confirmWithPassword(String password) async {
    final User? current = _auth.currentUser;
    final String? email = current?.email;
    if (current == null || email == null) {
      return const AuthResult.failed(AuthFailure.noSuchUser);
    }
    return _guard(() => current.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: email, password: password),
        ));
  }

  Future<AuthResult> confirmWithGoogle() async {
    final User? current = _auth.currentUser;
    if (current == null) return const AuthResult.failed(AuthFailure.noSuchUser);
    return _guard(() async {
      await GoogleSignIn.instance.initialize();
      final GoogleSignInAccount account =
          await GoogleSignIn.instance.authenticate();
      final GoogleSignInClientAuthorization authorization = await account
          .authorizationClient
          .authorizeScopes(<String>['email', 'profile']);
      await current.reauthenticateWithCredential(
        GoogleAuthProvider.credential(
          idToken: account.authentication.idToken,
          accessToken: authorization.accessToken,
        ),
      );
    });
  }

  /// Play requires an in-app way to delete the account *and* the data with it.
  ///
  /// The documents go first and the account last: an interrupted run then
  /// leaves an account the user can sign back into and retry, rather than
  /// orphaned data under a uid nobody can authenticate as. Cloud Functions
  /// would do this server-side and survive the app being killed, but they are
  /// Blaze-only, so it runs here.
  Future<AuthResult> deleteAccount() async {
    final User? current = _auth.currentUser;
    if (current == null) return const AuthResult.failed(AuthFailure.noSuchUser);

    return _guard(() async {
      await FirestoreSyncTarget.deleteEverythingFor(
        firestore: _firestore,
        uid: current.uid,
      );
      await current.delete();
      await GoogleSignIn.instance.signOut();
    });
  }

  /// Whether Firebase says [user]'s account no longer exists. A device that
  /// was signed in when another one deleted the account keeps a working ID
  /// token for up to an hour, and the rules accept it, so its next sync would
  /// quietly fill the deleted account up again. Anything short of a definite
  /// answer — offline, a slow server — reads as still there, and the run then
  /// fails or succeeds on its own terms.
  static Future<bool> isDeleted(User user) async {
    try {
      await user.reload();
      return false;
    } on FirebaseAuthException catch (error) {
      return const <String>{
        'user-not-found',
        'user-disabled',
        'user-token-expired',
      }.contains(error.code);
    } catch (error, stack) {
      reportError(error, stack, where: 'account check');
      return false;
    }
  }

  Future<AuthResult> _guard(Future<void> Function() run) async {
    try {
      await run();
      return const AuthResult.ok();
    } on FirebaseAuthException catch (error) {
      return AuthResult.failed(reasonFor(error.code));
    } on GoogleSignInException catch (error) {
      return AuthResult.failed(
        error.code == GoogleSignInExceptionCode.canceled
            ? AuthFailure.cancelled
            : AuthFailure.unknown,
      );
    } catch (error, stack) {
      reportError(error, stack, where: 'account');
      return AuthResult.failed(AuthFailure.unknown, message: '$error');
    }
  }

  /// Exposed because a typo here degrades every message to "something went
  /// wrong" without failing anything.
  @visibleForTesting
  static AuthFailure reasonFor(String code) {
    switch (code) {
      case 'network-request-failed':
        return AuthFailure.network;
      case 'wrong-password':
      case 'invalid-credential':
        return AuthFailure.wrongPassword;
      case 'user-not-found':
        return AuthFailure.noSuchUser;
      case 'email-already-in-use':
        return AuthFailure.emailInUse;
      case 'weak-password':
        return AuthFailure.weakPassword;
      case 'invalid-email':
        return AuthFailure.invalidEmail;
      case 'account-exists-with-different-credential':
        return AuthFailure.differentSignInMethod;
      case 'requires-recent-login':
        return AuthFailure.needsRecentLogin;
      case 'user-mismatch':
        return AuthFailure.wrongAccount;
      default:
        return AuthFailure.unknown;
    }
  }
}
