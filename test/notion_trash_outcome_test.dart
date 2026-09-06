import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/features/settings/notion_template_migration.dart';

void main() {
  test('one that went says so without counting', () {
    expect(
      notionTrashOutcome(moved: 1, of: 1),
      'Moved to the trash in Notion.',
    );
  });

  test('several that went are counted', () {
    expect(
      notionTrashOutcome(moved: 3, of: 3),
      'Moved 3 to the trash in Notion.',
    );
  });

  test('a batch that partly failed says how much of it did', () {
    // The one case a device cannot be made to show: it needs a call to fail
    // for a reason that is not "already gone", which the app counts as success.
    expect(
      notionTrashOutcome(moved: 2, of: 3),
      'Moved 2. Could not move 1 — it can be deleted in Notion instead.',
    );
    expect(
      notionTrashOutcome(moved: 1, of: 3),
      'Moved 1. Could not move 2 — they can be deleted in Notion instead.',
    );
  });

  test('nothing that went points at Notion instead', () {
    expect(
      notionTrashOutcome(moved: 0, of: 1),
      'Could not move it. It can be deleted in Notion instead.',
    );
    expect(
      notionTrashOutcome(moved: 0, of: 2),
      'Could not move them. They can be deleted in Notion instead.',
    );
  });
}
