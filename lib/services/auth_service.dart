import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

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

  cancelled,
  unknown,
}

@immutable
class AuthResult {
  const AuthResult.ok() : failure = null, message = null;
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

  Future<AuthResult> signUp(String email, String password) =>
      _guard(() => _auth.createUserWithEmailAndPassword(
            email: email.trim(),
            password: password,
          ));

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

  Future<void> signOut() async {
    await GoogleSignIn.instance.signOut();
    await _auth.signOut();
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
      await _deleteSubtree(_firestore.collection('users').doc(current.uid));
      await current.delete();
      await GoogleSignIn.instance.signOut();
    });
  }

  /// Firestore does not delete a document's subcollections with it, and the
  /// names are known here rather than discoverable from the client.
  Future<void> _deleteSubtree(DocumentReference<Map<String, Object?>> root) async {
    for (final String name in const <String>['subjects', 'attendance']) {
      QuerySnapshot<Map<String, Object?>> page =
          await root.collection(name).limit(400).get();
      while (page.docs.isNotEmpty) {
        final WriteBatch batch = _firestore.batch();
        for (final QueryDocumentSnapshot<Map<String, Object?>> doc
            in page.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        page = await root.collection(name).limit(400).get();
      }
    }
    await root.delete();
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
    } catch (error) {
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
      default:
        return AuthFailure.unknown;
    }
  }
}
