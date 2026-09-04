import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/notification_service.dart';

/// The warning runs on every mark, edit and sync, so what stops it repeating
/// itself is the record of what it has already said.
void main() {
  DangerDecision decide(Set<int> inDanger, Set<int> warned) =>
      NotificationService.decideDangerAlert(
        inDanger: inDanger,
        warned: warned,
      );

  test('the first slip is raised', () {
    final DangerDecision d = decide(<int>{1}, <int>{});

    expect(d.action, DangerAlert.raise);
    expect(d.warned, <int>{1});
  });

  test('marking another class leaves the standing warning alone', () {
    expect(decide(<int>{1}, <int>{1}).action, DangerAlert.leave);
  });

  test('a second subject slipping is news, and both are named', () {
    final DangerDecision d = decide(<int>{1, 2}, <int>{1});

    expect(d.action, DangerAlert.raise);
    expect(d.warned, <int>{1, 2});
  });

  test('recovering clears the warning', () {
    final DangerDecision d = decide(<int>{}, <int>{1});

    expect(d.action, DangerAlert.clear);
    expect(d.warned, isEmpty);
  });

  test('a subject that recovers and slips again warns afresh', () {
    final Set<int> afterRecovery = decide(<int>{}, <int>{1}).warned;

    expect(decide(<int>{1}, afterRecovery).action, DangerAlert.raise);
  });

  test('one recovering does not re-raise the one still down', () {
    final DangerDecision d = decide(<int>{1}, <int>{1, 2});

    expect(d.action, DangerAlert.leave);
    // Subject 2 is forgotten here, so its next slip is news again.
    expect(d.warned, <int>{1});
  });
}
