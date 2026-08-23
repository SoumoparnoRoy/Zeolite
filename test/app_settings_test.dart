import 'package:zeolite/data/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('notification gating', () {
    test('everything is on by default', () {
      const AppSettings settings = AppSettings();
      expect(settings.notificationsEnabled, isTrue);
      expect(settings.inAppAlerts, isTrue);
      expect(settings.classRemindersActive, isTrue);
      expect(settings.eveningReminderActive, isTrue);
      expect(settings.dangerAlertsActive, isTrue);
    });

    test('the master switch overrides every type', () {
      const AppSettings settings = AppSettings(notificationsEnabled: false);
      expect(settings.classRemindersActive, isFalse);
      expect(settings.eveningReminderActive, isFalse);
      expect(settings.dangerAlertsActive, isFalse);
    });

    test('turning the master switch off preserves the per-type choices', () {
      const AppSettings before = AppSettings(notifyEveningReminder: false);
      final AppSettings after = before.copyWith(notificationsEnabled: false);
      final AppSettings restored = after.copyWith(notificationsEnabled: true);

      // The evening reminder was off before and must still be off after the
      // round trip; the master switch must not silently re-enable it.
      expect(restored.notifyEveningReminder, isFalse);
      expect(restored.notifyBeforeClass, isTrue);
    });

    test('one type off leaves the others alone', () {
      const AppSettings settings = AppSettings(notifyBeforeClass: false);
      expect(settings.classRemindersActive, isFalse);
      expect(settings.eveningReminderActive, isTrue);
      expect(settings.dangerAlertsActive, isTrue);
    });
  });

  group('in-app alerts', () {
    test('are not raised while the tray is handling the warning', () {
      const AppSettings settings = AppSettings();
      expect(settings.dangerAlertsActive, isTrue);
      expect(settings.showDangerInApp, isFalse);
    });

    test('take over when the attendance alert type is switched off', () {
      const AppSettings settings =
          AppSettings(notifyAttendanceDanger: false);
      expect(settings.showDangerInApp, isTrue);
    });

    test('take over when the master switch is off', () {
      const AppSettings settings = AppSettings(notificationsEnabled: false);
      expect(settings.showDangerInApp, isTrue);
    });

    test('stay silent when the user has opted out of them too', () {
      const AppSettings settings = AppSettings(
        notificationsEnabled: false,
        inAppAlerts: false,
      );
      expect(settings.showDangerInApp, isFalse);
    });
  });

  group('theme mode', () {
    test('an existing install stays dark rather than changing on update', () {
      expect(const AppSettings().themeMode, AppThemeMode.dark);
    });

    test('an unknown or missing stored name falls back to dark', () {
      expect(AppThemeMode.fromName(null), AppThemeMode.dark);
      expect(AppThemeMode.fromName(''), AppThemeMode.dark);
      expect(AppThemeMode.fromName('sepia'), AppThemeMode.dark);
    });

    test('every mode round-trips through its stored name', () {
      for (final AppThemeMode mode in AppThemeMode.values) {
        expect(AppThemeMode.fromName(mode.name), mode);
      }
    });

    test('is carried through a backup', () {
      const AppSettings settings = AppSettings(themeMode: AppThemeMode.light);
      expect(
        AppSettings.fromJson(settings.toJson()).themeMode,
        AppThemeMode.light,
      );
    });

    test('a backup taken before themes existed restores as dark', () {
      final AppSettings restored =
          AppSettings.fromJson(<String, Object?>{'targetPercent': 75});
      expect(restored.themeMode, AppThemeMode.dark);
    });
  });

  group('backup round trip', () {
    test('carries the new flags', () {
      const AppSettings settings = AppSettings(
        notificationsEnabled: false,
        inAppAlerts: false,
      );
      final AppSettings restored = AppSettings.fromJson(settings.toJson());
      expect(restored.notificationsEnabled, isFalse);
      expect(restored.inAppAlerts, isFalse);
    });

    test('an older backup without the flags restores them as on', () {
      final AppSettings restored = AppSettings.fromJson(<String, Object?>{
        'targetPercent': 75,
        'notifyBeforeClass': true,
      });
      expect(restored.notificationsEnabled, isTrue);
      expect(restored.inAppAlerts, isTrue);
    });

    test('carries the break, and an older backup restores without one', () {
      const AppSettings settings = AppSettings(
        blockMinutes: 50,
        breakAfterBlock: 4,
        breakMinutes: 40,
      );
      final AppSettings restored = AppSettings.fromJson(settings.toJson());
      expect(restored.breakAfterBlock, 4);
      expect(restored.breakMinutes, 40);
      expect(restored.dayGrid.hasBreak, isTrue);

      final AppSettings older =
          AppSettings.fromJson(<String, Object?>{'blockMinutes': 50});
      expect(older.dayGrid.hasBreak, isFalse);
    });
  });
}
