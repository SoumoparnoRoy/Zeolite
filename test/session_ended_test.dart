import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/state/auth_providers.dart';

class _SignedInAs implements User {
  _SignedInAs(this.uid);

  @override
  final String uid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a later sign-in takes back an unsaid session end', () async {
    final StreamController<User?> users = StreamController<User?>();
    addTearDown(users.close);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signedInUserProvider.overrideWith((Ref ref) => users.stream),
      ],
    );
    addTearDown(container.dispose);
    container.listen(sessionEndedProvider, (_, __) {});

    users.add(null);
    await container.read(signedInUserProvider.future);
    container.read(sessionEndedProvider.notifier).ended();
    expect(container.read(sessionEndedProvider), isTrue);

    users.add(_SignedInAs('uid-again'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sessionEndedProvider), isFalse);
  });
}
