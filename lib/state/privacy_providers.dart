import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/report_error.dart';
import '../data/settings/app_settings.dart';
import '../services/auth_service.dart';
import '../services/collection_switches.dart';
import '../services/firebase/app_check_starter.dart';
import 'auth_providers.dart';
import 'providers.dart';

/// Does nothing where Firebase did not start.
final collectionSwitchesProvider = Provider<CollectionSwitches>(
  (ref) => Firebase.apps.isEmpty
      ? const NoCollectionSwitches()
      : const FirebaseCollectionSwitches(),
);

/// Hands the stored choices to the SDKs whenever they change, and once at
/// start. Watched for its lifetime by the app root.
///
/// Nothing is applied while settings load, which is safe: the SDKs start from
/// the manifest's off, or from the last choice they were given.
final collectionChoicesProvider = Provider<void>((ref) {
  final (bool, bool)? allowed = ref.watch(settingsProvider.select(
    (AsyncValue<AppSettings> s) => switch (s.value) {
      final AppSettings v => (v.usageAllowed, v.crashReportsAllowed),
      null => null,
    },
  ));
  if (allowed == null) return;
  final (bool usage, bool crashes) = allowed;
  unawaited(
    ref
        .read(collectionSwitchesProvider)
        .apply(usage: usage, crashes: crashes)
        .catchError((Object error, StackTrace stack) =>
            reportError(error, stack, where: 'collection choices')),
  );
});

final appCheckStarterProvider = Provider<AppCheckStarter>(
  (ref) => Firebase.apps.isEmpty
      ? const NoAppCheckStarter()
      : FirebaseAppCheckStarter(),
);

/// Activates App Check the first time the answer is a yes: at start for an
/// install that already said so, or the moment someone says it. An account
/// sync waits on it, or the launch run reaches Firestore before the token.
final appCheckProvider = FutureProvider<void>((ref) async {
  if (!ref.watch(servicesAllowedProvider)) return;
  try {
    await ref.read(appCheckStarterProvider).activate();
  } catch (error, stack) {
    reportError(error, stack, where: 'App Check start-up');
  }
});

final privacyChoicesProvider = Provider<PrivacyChoices>(PrivacyChoices.new);

/// Every write of the age answer and the two collection choices.
class PrivacyChoices {
  PrivacyChoices(this._ref);

  final Ref _ref;

  Future<void> _save(AppSettings Function(AppSettings) change) async {
    final AppSettings? current = _ref.read(settingsProvider).value;
    if (current == null) return;
    await _ref.read(settingsProvider.notifier).save(change(current));
  }

  /// No signs out of an account straight away: a signed-in session refreshes
  /// its token with Google, and under 18 nothing goes to Firebase at all.
  /// Yes, given from Settings, leaves both choices off rather than unanswered,
  /// since the switches the answer reveals already say so.
  Future<void> setAdult(bool adult, {bool fromSettings = false}) async {
    await _save((AppSettings s) {
      final AppSettings answered = s.copyWith(adult: adult);
      if (!adult || !fromSettings) return answered;
      return answered.copyWith(
        shareUsage: s.shareUsage ?? false,
        sendCrashReports: s.sendCrashReports ?? false,
      );
    });
    // Read from Firebase itself rather than the provider, which stops
    // listening before the answer is in: a session restored on an install
    // updating into this version is still there underneath.
    if (!adult && Firebase.apps.isNotEmpty) {
      final AuthService auth = _ref.read(authServiceProvider);
      if (auth.user != null) await auth.signOut();
    }
  }

  Future<void> setCollection({required bool usage, required bool crashes}) =>
      _save((AppSettings s) =>
          s.copyWith(shareUsage: usage, sendCrashReports: crashes));

  Future<void> setShareUsage(bool value) =>
      _save((AppSettings s) => s.copyWith(shareUsage: value));

  Future<void> setSendCrashReports(bool value) =>
      _save((AppSettings s) => s.copyWith(sendCrashReports: value));
}
