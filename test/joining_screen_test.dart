import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_status.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/features/launch/joining_screen.dart';
import 'package:zeolite/features/launch/launch_painter.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/state/sync_providers.dart';

/// Both controllers are replaced rather than seeded: the real ones resolve the
/// account through Firebase, which a widget test has no business reaching.
class _Settings extends SettingsController {
  _Settings(this._value);

  AppSettings _value;

  @override
  Future<AppSettings> build() async => _value;

  void set(AppSettings value) {
    _value = value;
    state = AsyncValue<AppSettings>.data(value);
  }
}

class _Sync extends SyncController {
  _Sync(this._value);

  SyncStatus _value;

  @override
  SyncStatus build() => _value;

  void set(SyncStatus value) {
    _value = value;
    state = value;
  }
}

void main() {
  late _Settings settings;
  late _Sync sync;
  late int done;

  setUp(() {
    settings = _Settings(const AppSettings(welcomeShown: true));
    sync = _Sync(const SyncStatus());
    done = 0;
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => settings),
          syncStatusProvider.overrideWith(() => sync),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: JoiningScreen(
            colors: LaunchColors.of(AccentColour.violet),
            onDone: () => done++,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an account that knows the term opens the app straight away',
      (WidgetTester tester) async {
    await show(tester);
    sync.set(const SyncStatus().running());
    await tester.pump();
    expect(done, 0, reason: 'the run is still reading the account');

    settings.set(const AppSettings(welcomeShown: true, onboarded: true));
    sync.set(SyncStatus().succeeded(DateTime(2026, 9, 4)));
    await tester.pump();

    expect(done, 1);
  });

  testWidgets('a run that ends with no term hands over to the questions',
      (WidgetTester tester) async {
    await show(tester);
    sync.set(const SyncStatus().running());
    await tester.pump();
    sync.set(SyncStatus().succeeded(DateTime(2026, 9, 4)));
    await tester.pump();

    expect(done, 1);
    expect(settings.state.value!.onboarded, isFalse);
  });

  testWidgets('a target that never answers is waited out, not waited on',
      (WidgetTester tester) async {
    await show(tester);
    sync.set(const SyncStatus().running());
    await tester.pump(const Duration(seconds: 5));
    expect(done, 0);

    await tester.pump(JoiningScreen.wait);

    expect(done, 1);
  });

  testWidgets('a failure hands over rather than holding the screen',
      (WidgetTester tester) async {
    await show(tester);
    sync.set(const SyncStatus().failed(SyncFailure.offline));
    await tester.pump();

    expect(done, 1);
  });
}
