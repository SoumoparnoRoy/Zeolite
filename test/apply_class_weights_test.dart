import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/state/providers.dart';

/// Records what the action asked the database to do instead of doing it.
class _Recording extends ZeoliteRepository {
  _Recording(this.stored);

  final List<AttendanceRecord> stored;
  final List<ClassSlot> slots = <ClassSlot>[];
  final List<ExtraClass> extras = <ExtraClass>[];
  List<AttendanceRecord> written = <AttendanceRecord>[];
  int snapshots = 0;

  @override
  Future<DatabaseSnapshot> snapshot() async {
    snapshots++;
    return <String, List<Map<String, Object?>>>{};
  }

  @override
  Future<List<AttendanceRecord>> getAttendance() async => stored;

  @override
  Future<void> updateSlot(ClassSlot slot) async => slots.add(slot);

  @override
  Future<void> updateExtraClass(ExtraClass extra) async => extras.add(extra);

  @override
  Future<void> setManyAttendance(List<AttendanceRecord> records) async =>
      written = records;
}

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

/// Two subjects: one filed as a Lab, one in no category at all, which is the
/// state every subject starts in.
ClassCategory _labWorth(int weight) => ClassCategory(
      id: 7,
      name: 'Lab',
      defaultDurationMinutes: 120,
      weight: weight,
    );

const Subject _practical =
    Subject(id: 1, name: 'Generic Practical', colorValue: 0xFF7C6BFF,
        categoryId: 7);

const Subject _lecture =
    Subject(id: 2, name: 'Generic Lecture', colorValue: 0xFF33CC88);

final DateTime _day = Dates.addDays(Dates.today(), -7);

ClassSlot _slot(int subjectId, int weight) => ClassSlot(
      id: subjectId,
      subjectId: subjectId,
      weekday: DateTime.monday,
      startMinutes: 540,
      endMinutes: 660,
      weight: weight,
      startDate: _day,
    );

AttendanceRecord _mark(int subjectId, int weight) => AttendanceRecord(
      subjectId: subjectId,
      date: _day,
      startMinutes: 540,
      status: AttendanceStatus.present,
      weight: weight,
    );

Future<(ProviderContainer, _Recording)> _harness({
  int labWeight = 2,
  List<AttendanceRecord> stored = const <AttendanceRecord>[],
}) async {
  final _Recording repo = _Recording(stored);
  final ProviderContainer container = ProviderContainer(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      timetableProvider.overrideWith((Ref ref) async => TimetableData(
            categories: <ClassCategory>[_labWorth(labWeight)],
            subjects: const <Subject>[_practical, _lecture],
            slots: <ClassSlot>[_slot(1, 1), _slot(2, 1)],
            extras: const <ExtraClass>[],
            holidays: const <Holiday>[],
            records: const <AttendanceRecord>[],
          )),
      settingsProvider.overrideWith(_StaticSettings.new),
    ],
  );
  addTearDown(container.dispose);
  await container.read(timetableProvider.future);
  await container.read(settingsProvider.future);
  return (container, repo);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a slot takes the weight its category says, and one out of a category '
      'is left worth one', () async {
    final (ProviderContainer container, _Recording repo) = await _harness();

    await container.read(actionsProvider).applyClassWeights();

    // Only the lab moved: nothing here has anything to say about a subject
    // in no category.
    expect(repo.slots.single.subjectId, 1);
    expect(repo.slots.single.weight, 2);
  });

  test('only marks that actually move are rewritten', () async {
    final (ProviderContainer container, _Recording repo) = await _harness(
      stored: <AttendanceRecord>[_mark(1, 1), _mark(2, 1)],
    );

    // The lecture is already worth one, so it is left alone; rewriting every
    // row would make the returned count meaningless.
    final int changed = await container
        .read(actionsProvider)
        .applyClassWeights();

    expect(changed, 1);
    expect(repo.written.single.subjectId, 1);
    expect(repo.written.single.weight, 2);
  });

  test('it takes a snapshot first, so one Undo puts history back', () async {
    final (ProviderContainer container, _Recording repo) = await _harness(
      stored: <AttendanceRecord>[_mark(1, 1)],
    );

    await container.read(actionsProvider).applyClassWeights();

    expect(repo.snapshots, 1);
    expect(container.read(actionsProvider).pendingUndoToken, isNotNull);
  });

  test('a category worth nothing is applied, not read as unset', () async {
    final (ProviderContainer container, _Recording repo) = await _harness(
      labWeight: 0,
      stored: <AttendanceRecord>[_mark(1, 2)],
    );

    await container.read(actionsProvider).applyClassWeights();

    // Reading a zero as "unset" would leave this worth one, which is the bug
    // this pins.
    expect(repo.written.single.weight, 0);
    expect(repo.slots.firstWhere((ClassSlot s) => s.subjectId == 1).weight, 0);
  });
}
