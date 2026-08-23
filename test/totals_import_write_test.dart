import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/attendance_totals_import.dart';
import 'package:zeolite/domain/attendance_totals_ocr.dart';
import 'package:zeolite/state/providers.dart';

/// Records what the import asked the database to do instead of doing it.
class _Recording extends ZeoliteRepository {
  final List<Subject> inserted = <Subject>[];
  final List<Subject> updated = <Subject>[];
  final List<int> clearedFor = <int>[];
  int snapshots = 0;

  @override
  Future<DatabaseSnapshot> snapshot() async {
    snapshots++;
    return <String, List<Map<String, Object?>>>{};
  }

  @override
  Future<int> insertSubject(Subject subject) async {
    inserted.add(subject);
    return 90 + inserted.length;
  }

  @override
  Future<void> updateSubject(Subject subject) async => updated.add(subject);

  @override
  Future<int> clearAttendanceBetween(int id, DateTime from, DateTime to) async {
    clearedFor.add(id);
    return 1;
  }
}

class _StaticSettings extends SettingsController {
  _StaticSettings({this.dated = true});

  final bool dated;

  @override
  Future<AppSettings> build() async => AppSettings(
        onboarded: true,
        semesterStart: dated ? Dates.addDays(Dates.today(), -30) : null,
        semesterEnd: dated ? Dates.addDays(Dates.today(), 60) : null,
      );
}

const Subject _signals = Subject(
  id: 1,
  name: 'Signal Theory',
  colorValue: 0xFF7C6BFF,
  priorHeld: 4,
  priorAttended: 3,
);

TimetableData _data() => const TimetableData(
      categories: <ClassCategory>[],
      subjects: <Subject>[_signals],
      slots: <ClassSlot>[],
      extras: <ExtraClass>[],
      holidays: <Holiday>[],
      records: <AttendanceRecord>[],
    );

TotalsRow _row(String name) => TotalsRow(
      subject: name,
      expectedTotal: 18,
      held: 16,
      attended: 14,
    );

Future<(ProviderContainer, _Recording)> _harness({bool dated = true}) async {
  final _Recording repo = _Recording();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      timetableProvider.overrideWith((Ref ref) async => _data()),
      settingsProvider.overrideWith(() => _StaticSettings(dated: dated)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(timetableProvider.future);
  await container.read(settingsProvider.future);
  return (container, repo);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a row with no subject of that name creates one with the balance',
      () async {
    final (ProviderContainer container, _Recording repo) = await _harness();

    final int count = await container
        .read(actionsProvider)
        .importAttendanceTotals(<TotalsDecision>[
      TotalsDecision(row: _row('Control Systems')),
    ]);

    expect(count, 1);
    expect(repo.inserted, hasLength(1));
    final Subject made = repo.inserted.single;
    expect(made.name, 'Control Systems');
    expect(made.priorHeld, 16);
    expect(made.priorAttended, 14);
    expect(made.expectedTotal, 18);
    expect(repo.updated, isEmpty);
  });

  test('a matched row replaces the balance and keeps the rest of the subject',
      () async {
    final (ProviderContainer container, _Recording repo) = await _harness();

    await container
        .read(actionsProvider)
        .importAttendanceTotals(<TotalsDecision>[
      TotalsDecision(row: _row('Signal Theory'), subjectId: 1),
    ]);

    expect(repo.inserted, isEmpty);
    final Subject saved = repo.updated.single;
    expect(saved.id, 1);
    expect(saved.priorHeld, 16);
    expect(saved.priorAttended, 14);
    // Everything the portal knows nothing about survives.
    expect(saved.name, 'Signal Theory');
    expect(saved.colorValue, 0xFF7C6BFF);
    expect(repo.clearedFor, isEmpty);
  });

  test('only a row asking to clear marks clears them', () async {
    final (ProviderContainer container, _Recording repo) = await _harness();

    await container
        .read(actionsProvider)
        .importAttendanceTotals(<TotalsDecision>[
      TotalsDecision(row: _row('Signal Theory'), subjectId: 1, clearMarks: true),
    ]);

    expect(repo.clearedFor, <int>[1]);
    expect(repo.updated.single.priorHeld, 16);
  });

  test('the whole import is one undo snapshot, taken before anything is written',
      () async {
    final (ProviderContainer container, _Recording repo) = await _harness();

    await container
        .read(actionsProvider)
        .importAttendanceTotals(<TotalsDecision>[
      TotalsDecision(row: _row('Control Systems')),
      TotalsDecision(row: _row('Imaging Lab')),
      TotalsDecision(row: _row('Signal Theory'), subjectId: 1),
    ]);

    expect(repo.snapshots, 1);
    expect(container.read(actionsProvider).pendingUndoToken, isNotNull);
  });

  test('clearing still happens when no semester dates are set', () async {
    // countsInTerm counts every mark when there are no dates, so the preview
    // weighs them all. Clearing has to cover the same marks or the balance is
    // written on top of them.
    final (ProviderContainer container, _Recording repo) =
        await _harness(dated: false);

    await container
        .read(actionsProvider)
        .importAttendanceTotals(<TotalsDecision>[
      TotalsDecision(row: _row('Signal Theory'), subjectId: 1, clearMarks: true),
    ]);

    expect(repo.clearedFor, <int>[1]);
  });

  test('a subject deleted while the preview was open is skipped, not fatal',
      () async {
    final (ProviderContainer container, _Recording repo) = await _harness();

    final int count = await container
        .read(actionsProvider)
        .importAttendanceTotals(<TotalsDecision>[
      TotalsDecision(row: _row('Gone'), subjectId: 404),
      TotalsDecision(row: _row('Control Systems')),
    ]);

    expect(count, 2);
    expect(repo.updated, isEmpty);
    expect(repo.inserted, hasLength(1));
  });

  test('an empty decision list writes nothing and arms no undo', () async {
    final (ProviderContainer container, _Recording repo) = await _harness();

    final int count = await container
        .read(actionsProvider)
        .importAttendanceTotals(const <TotalsDecision>[]);

    expect(count, 0);
    expect(repo.snapshots, 0);
    expect(repo.inserted, isEmpty);
    expect(container.read(actionsProvider).pendingUndoToken, isNull);
  });
}
