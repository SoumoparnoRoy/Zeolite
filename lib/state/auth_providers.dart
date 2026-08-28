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
