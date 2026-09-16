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

import 'fake_notifications.dart';

/// Marks are filed under `(subject, date, start time)` and have no link to the
/// class they came from, so re-pointing a class leaves them behind. These
/// cover the half of the fix that touches the database.
class _Recording extends ZeoliteRepository {
  final List<ClassSlot> slots = <ClassSlot>[];
  final List<ExtraClass> extras = <ExtraClass>[];
  final List<AttendanceRecord> written = <AttendanceRecord>[];
  final List<String> cleared = <String>[];
  AttendanceRecord? existing;

  @override
  Future<T> transaction<T>(
    Future<T> Function(ZeoliteRepository repository) action,
  ) =>
      action(this);

  @override
  Future<DatabaseSnapshot> snapshot() async =>
      <String, List<Map<String, Object?>>>{};

  @override
  Future<void> updateSlot(ClassSlot slot) async => slots.add(slot);

  @override
  Future<void> updateExtraClass(ExtraClass extra) async => extras.add(extra);

  @override
  Future<void> setAttendance(AttendanceRecord record) async =>
      written.add(record);

  @override
  Future<AttendanceRecord?> getAttendanceAt(
    int subjectId,
    DateTime date,
    int startMinutes,
  ) async =>
      existing;

  @override
  Future<void> clearAttendance(
    int subjectId,
    DateTime date,
    int startMinutes,
  ) async =>
      cleared.add('$subjectId:${Dates.keyOf(date)}:$startMinutes');
}

class _StaticSettings extends SettingsController {
  @override
  Future<AppSettings> build() async => const AppSettings(onboarded: true);
}

const Subject _chemistry =
    Subject(id: 1, name: 'Subject 1', colorValue: 0xFF7C6BFF);
const Subject _physics =
    Subject(id: 2, name: 'Subject 2', colorValue: 0xFF33CC88);

/// Two Mondays back, so both are inside the slot and safely in the past.
final DateTime _start = Dates.addDays(Dates.today(), -21);
final DateTime _firstMonday = _mondayOnOrAfter(_start);
final DateTime _secondMonday = Dates.addDays(_firstMonday, 7);

DateTime _mondayOnOrAfter(DateTime from) {
  DateTime day = from;
  while (day.weekday != DateTime.monday) {
    day = Dates.addDays(day, 1);
  }
  return day;
}

final ClassSlot _slot = ClassSlot(
  id: 5,
  subjectId: _chemistry.id!,
  weekday: DateTime.monday,
  startMinutes: 9 * 60,
  endMinutes: 10 * 60,
  startDate: _start,
);

AttendanceRecord _mark(
  int subjectId,
  DateTime date, {
  int startMinutes = 9 * 60,
}) =>
    AttendanceRecord(
      subjectId: subjectId,
      date: date,
      startMinutes: startMinutes,
      status: AttendanceStatus.present,
    );

Future<(ProviderContainer, _Recording)> _harness({
  List<AttendanceRecord> records = const <AttendanceRecord>[],
  List<ExtraClass> extras = const <ExtraClass>[],
}) async {
  final _Recording repo = _Recording();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      notificationsProvider.overrideWithValue(QuietNotifications()),
      repositoryProvider.overrideWithValue(repo),
      timetableProvider.overrideWith((Ref ref) async => TimetableData(
            categories: const <ClassCategory>[],
            subjects: const <Subject>[_chemistry, _physics],
            slots: <ClassSlot>[_slot],
            extras: extras,
            holidays: const <Holiday>[],
            records: records,
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

  group('re-pointing a weekly class', () {
    test('carries every mark to the new subject, keeping their dates',
        () async {
      final (ProviderContainer container, _Recording repo) = await _harness(
        records: <AttendanceRecord>[
          _mark(_chemistry.id!, _firstMonday),
          _mark(_chemistry.id!, _secondMonday),
        ],
      );

      await container.read(actionsProvider).updateSlotAndMoveMarks(
            _slot,
            _slot.copyWith(subjectId: _physics.id),
          );

      expect(repo.written.length, 2);
      expect(
        repo.written.every((AttendanceRecord r) => r.subjectId == _physics.id),
        isTrue,
      );
      expect(
        repo.written.map((AttendanceRecord r) => Dates.keyOf(r.date)).toSet(),
        <int>{Dates.keyOf(_firstMonday), Dates.keyOf(_secondMonday)},
      );
      expect(repo.cleared.length, 2);
    });

    test('leaves marks the class never covered alone', () async {
      // A different subject on the same morning, and the right subject on a
      // day this slot does not run.
      final (ProviderContainer container, _Recording repo) = await _harness(
        records: <AttendanceRecord>[
          _mark(_chemistry.id!, _firstMonday),
          _mark(_physics.id!, _firstMonday),
          _mark(_chemistry.id!, Dates.addDays(_firstMonday, 1)),
          _mark(_chemistry.id!, _firstMonday, startMinutes: 14 * 60),
        ],
      );

      await container.read(actionsProvider).updateSlotAndMoveMarks(
            _slot,
            _slot.copyWith(subjectId: _physics.id),
          );

      expect(repo.written.single.subjectId, _physics.id);
      expect(Dates.keyOf(repo.written.single.date), Dates.keyOf(_firstMonday));
      expect(
          repo.cleared.single,
          '${_chemistry.id}:'
          '${Dates.keyOf(_firstMonday)}:${9 * 60}');
    });

    test('a time change moves the marks without changing the subject',
        () async {
      final (ProviderContainer container, _Recording repo) = await _harness(
        records: <AttendanceRecord>[_mark(_chemistry.id!, _firstMonday)],
      );

      await container.read(actionsProvider).updateSlotAndMoveMarks(
            _slot,
            _slot.copyWith(startMinutes: 11 * 60, endMinutes: 12 * 60),
          );

      expect(repo.written.single.subjectId, _chemistry.id);
      expect(repo.written.single.startMinutes, 11 * 60);
      expect(repo.slots.single.startMinutes, 11 * 60);
    });
  });

  group('moving a one-off class', () {
    final ExtraClass extra = ExtraClass(
      id: 3,
      subjectId: _chemistry.id!,
      date: _firstMonday,
      startMinutes: 15 * 60,
      endMinutes: 16 * 60,
    );

    test('takes its mark to the new date as well as the new subject', () async {
      final (ProviderContainer container, _Recording repo) =
          await _harness(extras: <ExtraClass>[extra]);
      repo.existing = _mark(
        _chemistry.id!,
        _firstMonday,
        startMinutes: 15 * 60,
      );

      final ExtraClass moved = extra.copyWith(
        subjectId: _physics.id,
        date: _secondMonday,
      );
      await container
          .read(actionsProvider)
          .updateExtraClassAndMoveMarks(extra, moved);

      expect(repo.written.single.subjectId, _physics.id);
      expect(Dates.keyOf(repo.written.single.date), Dates.keyOf(_secondMonday));
      expect(
          repo.cleared.single,
          '${_chemistry.id}:'
          '${Dates.keyOf(_firstMonday)}:${15 * 60}');
    });

    test('an unmarked one-off just moves', () async {
      final (ProviderContainer container, _Recording repo) =
          await _harness(extras: <ExtraClass>[extra]);

      await container.read(actionsProvider).updateExtraClassAndMoveMarks(
            extra,
            extra.copyWith(subjectId: _physics.id),
          );

      expect(repo.written, isEmpty);
      expect(repo.cleared, isEmpty);
      expect(repo.extras.single.subjectId, _physics.id);
    });
  });
}
