import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/state/actions/action_core.dart';
import 'package:zeolite/widgets/undo_snack.dart';

class _Armed extends ActionCore {
  _Armed(super.ref);

  @override
  int? get pendingUndoToken => 1;
}

final Provider<ActionCore> _core = Provider<ActionCore>(_Armed.new);

void main() {
  testWidgets('the undo offer goes away on its own',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) => TextButton(
                onPressed: () => showUndoSnack(
                  ScaffoldMessenger.of(context),
                  ref.read(_core),
                  'All data deleted',
                ),
                child: const Text('Delete'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('All data deleted'), findsNothing);
  });
}
