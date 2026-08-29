import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/state/providers.dart';

/// Semester dates the tests measure against.
final DateTime _start = DateTime(2026, 8, 18);
final DateTime _end = DateTime(2026, 12, 16);

const Subject _physics =
    Subject(id: 1, name: 'Physics', colorValue: AppColors.defaultSubjectColor);

AttendanceRecord _present(DateTime date) => AttendanceRecord(
      subjectId: 1,
      date: date,
      startMinutes: 540,
      status: AttendanceStatus.present,
    );

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

/// Reads `statsProvider` against a fixture, waiting for the settings future so
/// the term window is in place before the stats are read.
Future<SubjectStats> _statsFor(
  List<AttendanceRecord> records, {
  AppSettings settings = const AppSettings(),
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(() => _StaticSettings(settings)),
      timetableProvider.overrideWith(
        (Ref ref) async => TimetableData(
          categories: const <ClassCategory>[],
          subjects: const <Subject>[_physics],
          slots: const <ClassSlot>[],
          extras: const <ExtraClass>[],
          holidays: const <Holiday>[],
          records: records,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(timetableProvider.future);
  return container.read(statsProvider).subjects.first;
}

void main() {
  group('a mark only counts inside the term', () {
    final AppSettings term =
        AppSettings(semesterStart: _start, semesterEnd: _end);

    test('one from before the semester started is left out', () async {
      final SubjectStats stats = await _statsFor(
        <AttendanceRecord>[_present(DateTime(2026, 8, 4))],
        settings: term,
      );
      expect(stats.held, 0);
    });

    test('one from after it ends is left out', () async {
      final SubjectStats stats = await _statsFor(
        <AttendanceRecord>[_present(DateTime(2026, 12, 17))],
        settings: term,
      );
      expect(stats.held, 0);
    });

    test('both end dates are inside it', () async {
      final SubjectStats stats = await _statsFor(
        <AttendanceRecord>[_present(_start), _present(_end)],
        settings: term,
      );
      expect(stats.held, 2);
    });

    test('without dates set there is no window, so everything counts',
        () async {
      final SubjectStats stats = await _statsFor(
        <AttendanceRecord>[_present(DateTime(2026, 8, 4))],
      );
      expect(stats.held, 1);
    });
  });

  group('the window itself', () {
    final AppSettings term =
        AppSettings(semesterStart: _start, semesterEnd: _end);

    test('is inclusive at both ends', () {
      expect(term.countsInTerm(_start), isTrue);
      expect(term.countsInTerm(_end), isTrue);
      expect(term.countsInTerm(DateTime(2026, 8, 17)), isFalse);
      expect(term.countsInTerm(DateTime(2026, 12, 17)), isFalse);
    });

    test('ignores the time of day', () {
      expect(term.countsInTerm(DateTime(2026, 8, 18, 23, 59)), isTrue);
    });

    test('half a semester is no window at all', () {
      const AppSettings half = AppSettings();
      expect(half.countsInTerm(DateTime(1999, 1, 1)), isTrue);
    });
  });

  group('counting the marks outside it', () {
    final AppSettings counting = AppSettings(
      semesterStart: _start,
      semesterEnd: _end,
      countOutsideTerm: true,
    );

    test('a mark from before the term counts once asked for', () async {
      final SubjectStats stats = await _statsFor(
        <AttendanceRecord>[_present(DateTime(2026, 8, 4))],
        settings: counting,
      );
      expect(stats.held, 1);
    });

    test('the window itself is unchanged, so the strays stay nameable', () {
      final DateTime stray = DateTime(2026, 8, 4);
      expect(counting.countsInTerm(stray), isFalse);
      expect(counting.countsTowardsPercentage(stray), isTrue);
    });
  });
}
