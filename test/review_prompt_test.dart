import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/schedule_engine.dart';
import 'package:zeolite/services/review_prompt.dart';

final DateTime monday = DateTime(2026, 8, 3);

ClassSlot _slot(int id, int weekday) => ClassSlot(
      id: id,
      subjectId: 1,
      weekday: weekday,
      startMinutes: 9 * 60,
      endMinutes: 10 * 60,
      startDate: monday,
    );

/// One subject on Monday and Wednesday, every week.
final List<ClassSlot> _slots = <ClassSlot>[
  _slot(1, DateTime.monday),
  _slot(2, DateTime.wednesday),
];

AttendanceRecord _mark(DateTime date, [AttendanceStatus? status]) =>
    AttendanceRecord(
      subjectId: 1,
      date: date,
      startMinutes: 9 * 60,
      status: status ?? AttendanceStatus.present,
    );

List<ClassSession> _weekOf(DateTime date, List<AttendanceRecord> marks) {
  final ScheduleEngine engine = ScheduleEngine(
    subjects: const <Subject>[
      Subject(id: 1, name: 'Subject A', colorValue: 0xFF7C6BFF),
    ],
    slots: _slots,
    extras: const [],
    holidays: const [],
    records: marks,
  );
  final DateTime start = Dates.startOfWeek(date);
  return engine.sessionsBetween(start, Dates.addDays(start, 6));
}

void main() {
  late int requests;
  late ReviewPrompt prompt;
  final DateTime wednesday = Dates.addDays(monday, 2);
  final DateTime nextMonday = Dates.addDays(monday, 7);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    requests = 0;
    prompt = ReviewPrompt(
      isAvailable: () async => true,
      request: () async => requests++,
    );
  });

  test('asks once the week is fully marked, and not before', () async {
    expect(await prompt.afterMark(_weekOf(monday, [_mark(monday)])), isFalse);
    expect(requests, 0);

    final bool asked = await prompt.afterMark(_weekOf(
      wednesday,
      [_mark(monday), _mark(wednesday, AttendanceStatus.cancelled)],
    ));
    expect(asked, isTrue);
    expect(requests, 1);
  });

  test('never asks again, even for a later full week', () async {
    await prompt.afterMark(_weekOf(monday, [_mark(monday), _mark(wednesday)]));
    final bool again = await prompt.afterMark(_weekOf(nextMonday, [
      _mark(nextMonday),
      _mark(Dates.addDays(nextMonday, 2)),
    ]));
    expect(again, isFalse);
    expect(requests, 1);

    // A fresh instance, as after a restart, reads the stored answer.
    final ReviewPrompt restarted = ReviewPrompt(
        isAvailable: () async => true, request: () async => requests++);
    expect(
        await restarted
            .afterMark(_weekOf(monday, [_mark(monday), _mark(wednesday)])),
        isFalse);
    expect(requests, 1);
  });

  test('a store that cannot be opened neither throws nor asks', () async {
    // Not set up: SharedPreferencesAsync() throws on first use.
    SharedPreferencesAsyncPlatform.instance = null;
    final List<ClassSession> full =
        _weekOf(monday, [_mark(monday), _mark(wednesday)]);
    int checks = 0;
    final ReviewPrompt prompt = ReviewPrompt(
      isAvailable: () async {
        checks++;
        return true;
      },
      request: () async => requests++,
    );
    expect(await prompt.afterMark(full), isFalse);
    expect(checks, 0, reason: 'stopped at the store, before Play');
    expect(requests, 0);
  });

  test('a week with no classes is not a finished week', () async {
    expect(await prompt.afterMark(const <ClassSession>[]), isFalse);
    expect(
        await SharedPreferencesAsync().getBool(ReviewPrompt.askedKey), isNull);
  });

  test('a card Play holds back or fails still uses up the one ask', () async {
    final ReviewPrompt failing = ReviewPrompt(
      isAvailable: () async => true,
      request: () async => throw StateError('no activity'),
    );
    final List<ClassSession> full =
        _weekOf(monday, [_mark(monday), _mark(wednesday)]);
    expect(await failing.afterMark(full), isFalse, reason: 'nothing thrown');
    expect(await prompt.afterMark(full), isFalse);
    expect(requests, 0);
  });

  test('two marks finishing the week at once ask only once', () async {
    final List<ClassSession> full =
        _weekOf(monday, [_mark(monday), _mark(wednesday)]);
    await Future.wait(<Future<bool>>[
      prompt.afterMark(full),
      prompt.afterMark(full),
    ]);
    expect(requests, 1);
  });
}
