import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/services/backup_service.dart';

void main() {
  group('when an automatic backup is due', () {
    final DateTime now = DateTime(2026, 8, 19, 13, 10);

    test('never while the setting is off', () {
      expect(
        BackupService.isAutoBackupDue(
          enabled: false,
          lastAt: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('on the first run after switching it on', () {
      expect(
        BackupService.isAutoBackupDue(enabled: true, lastAt: null, now: now),
        isTrue,
      );
    });

    test('not twice in the same day', () {
      expect(
        BackupService.isAutoBackupDue(
          enabled: true,
          lastAt: DateTime(2026, 8, 19, 6, 0),
          now: now,
        ),
        isFalse,
      );
    });

    test('once the date has rolled over', () {
      expect(
        BackupService.isAutoBackupDue(
          enabled: true,
          lastAt: DateTime(2026, 8, 18, 23, 59),
          now: now,
        ),
        isTrue,
      );
    });

    test('on a calendar day, not a 24-hour gap', () {
      // Eleven minutes apart across midnight still counts as a new day, which
      // is the behaviour someone opening the app each morning expects.
      expect(
        BackupService.isAutoBackupDue(
          enabled: true,
          lastAt: DateTime(2026, 8, 18, 23, 55),
          now: DateTime(2026, 8, 19, 0, 6),
        ),
        isTrue,
      );
    });

    test('a stamp from the future does not wedge it off forever', () {
      // A clock change backwards would otherwise suppress every future backup.
      expect(
        BackupService.isAutoBackupDue(
          enabled: true,
          lastAt: DateTime(2026, 9, 1),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('the backup filename', () {
    test('sorts chronologically as plain text', () {
      // The prune picks the oldest by name, so this ordering is load-bearing
      // rather than cosmetic.
      final List<String> names = <String>[
        BackupService.fileNameFor(DateTime(2026, 8, 19, 9, 5)),
        BackupService.fileNameFor(DateTime(2026, 8, 18, 23, 59)),
        BackupService.fileNameFor(DateTime(2026, 12, 1, 0, 0)),
        BackupService.fileNameFor(DateTime(2026, 8, 19, 13, 10)),
      ]..sort();

      expect(names.first, contains('20260818_2359'));
      expect(names.last, contains('20261201_0000'));
    });

    test('pads the hour and minute so widths never differ', () {
      expect(
        BackupService.fileNameFor(DateTime(2026, 8, 19, 9, 5)),
        'zeolite_backup_20260819_0905.json',
      );
    });
  });

  group('the setting itself', () {
    test('is off until it is asked for', () {
      expect(const AppSettings().autoBackupEnabled, isFalse);
      expect(const AppSettings().lastAutoBackupAt, isNull);
    });

    test('survives an export and import', () {
      final AppSettings restored = AppSettings.fromJson(
        const AppSettings(autoBackupEnabled: true).toJson(),
      );
      expect(restored.autoBackupEnabled, isTrue);
    });

    test('but the timestamp does not travel with the backup', () {
      // It is device state. Carrying it to another phone would tell that phone
      // a backup had already been taken today when none had.
      final AppSettings restored = AppSettings.fromJson(
        AppSettings(
          autoBackupEnabled: true,
          lastAutoBackupAt: DateTime(2026, 8, 19),
        ).toJson(),
      );
      expect(restored.lastAutoBackupAt, isNull);
    });

    test('a fallback to the app folder is kept on the device, not exported',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final SettingsService service = SettingsService();
      await service.save(
        const AppSettings(
            autoBackupEnabled: true, lastAutoBackupFellBack: true),
      );

      expect((await service.load()).lastAutoBackupFellBack, isTrue);
      expect(
        AppSettings.fromJson(
          const AppSettings(lastAutoBackupFellBack: true).toJson(),
        ).lastAutoBackupFellBack,
        isFalse,
      );
    });

    test('an older backup restores with it off', () {
      final Map<String, Object?> old = const AppSettings().toJson()
        ..remove('autoBackupEnabled');
      expect(AppSettings.fromJson(old).autoBackupEnabled, isFalse);
    });
  });
}
