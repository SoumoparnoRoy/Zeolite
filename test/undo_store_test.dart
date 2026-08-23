import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/state/undo.dart';

DatabaseSnapshot _snapshot(String marker) => <String, List<Map<String, Object?>>>{
      'subjects': <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'name': marker},
      ],
    };

String _nameIn(DatabaseSnapshot? snapshot) =>
    snapshot!['subjects']!.single['name']! as String;

void main() {
  group('the undo on offer', () {
    test('there is nothing to undo until something arms one', () {
      expect(UndoStore().pendingToken, isNull);
    });

    test('the armed snapshot comes back for its own token', () {
      final UndoStore store = UndoStore();
      final int token = store.arm(_snapshot('before'));

      expect(store.pendingToken, token);
      expect(_nameIn(store.take(token)), 'before');
    });

    test('an undo can only be taken once', () {
      final UndoStore store = UndoStore();
      final int token = store.arm(_snapshot('before'));

      store.take(token);
      expect(store.take(token), isNull);
      expect(store.pendingToken, isNull);
    });

    test('a mutation drops the offer', () {
      final UndoStore store = UndoStore();
      final int token = store.arm(_snapshot('before'));

      store.drop();

      expect(store.pendingToken, isNull);
      expect(store.take(token), isNull);
    });
  });

  group('a stale snackbar', () {
    // Delete two subjects quickly and the first snackbar can still be on screen
    // when the second delete arms its own snapshot. Honouring the first would
    // restore the wrong one.
    test('cannot restore the snapshot that replaced its own', () {
      final UndoStore store = UndoStore();
      final int first = store.arm(_snapshot('first'));
      final int second = store.arm(_snapshot('second'));

      expect(store.take(first), isNull);
      expect(_nameIn(store.take(second)), 'second');
    });

    test('leaves the current offer standing when it is refused', () {
      final UndoStore store = UndoStore();
      final int first = store.arm(_snapshot('first'));
      final int second = store.arm(_snapshot('second'));

      store.take(first);

      expect(store.pendingToken, second);
    });

    test('cannot be honoured by a later action reusing its token', () {
      final UndoStore store = UndoStore();
      final int first = store.arm(_snapshot('first'));
      store.drop();
      store.arm(_snapshot('second'));

      expect(store.take(first), isNull);
    });
  });
}
