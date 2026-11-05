import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/report_error.dart';
import '../data/settings/app_settings.dart';
import '../services/age_signals.dart';
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

final ageSignalsProvider = Provider<AgeSignals>((ref) => const AgeSignals());

/// Asks Google Play for the age range once per start, once settings have
/// loaded, and applies the answer. Nothing waits on it: the first-run
/// questions and the app draw as usual, and a reply moves them on. Watched for
/// its lifetime by the app root.
final playAgeProvider = FutureProvider<void>((ref) async {
  if (!ref.watch(
      settingsProvider.select((AsyncValue<AppSettings> s) => s.hasValue))) {
    return;
  }
  final PlayAge age = await ref.read(ageSignalsProvider).check();
  try {
    await ref.read(privacyChoicesProvider).applyPlayAge(age);
  } catch (error, stack) {
    // A failed settings write; the age itself is not in the error.
    reportError(error, stack, where: 'applying the Play age');
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
      final AppSettings answered =
          s.copyWith(adult: adult, ageFrom: AgeFrom.user);
      if (!adult || !fromSettings) return answered;
      return answered.copyWith(
        shareUsage: s.shareUsage ?? false,
        sendCrashReports: s.sendCrashReports ?? false,
      );
    });
    if (!adult) await _signOut();
  }

  /// Play's answer wins over the user's in one direction only: under 18 (or
  /// unconfirmed where the law asks for confirmation) locks the app on the
  /// device, and only Play saying 18 or over lifts that lock, after which the
  /// age question and both collection choices are asked again. Play saying 18
  /// or over otherwise only answers a question nobody has answered yet, so
  /// someone who chose on-device mode keeps it. No answer from Play changes
  /// nothing.
  Future<void> applyPlayAge(PlayAge age) async {
    final AppSettings? current = _ref.read(settingsProvider).value;
    if (current == null) return;
    switch (age) {
      case PlayAge.under18 || PlayAge.unverified:
        final AgeFrom from =
            age == PlayAge.under18 ? AgeFrom.play : AgeFrom.playUnverified;
        if (current.adult == false && current.ageFrom == from) return;
        await _save((AppSettings s) => s.copyWith(adult: false, ageFrom: from));
        await _signOut();
      case PlayAge.adult:
        if (current.ageLockedByPlay) {
          await _save((AppSettings s) => s.copyWith(clearAnswers: true));
        } else if (current.adult == null) {
          // The two collection choices stay unanswered, so the consent screen
          // still asks them with nothing chosen.
          await _save((AppSettings s) =>
              s.copyWith(adult: true, ageFrom: AgeFrom.play));
        }
      case PlayAge.none:
        return;
    }
  }

  /// Read from Firebase itself rather than the provider, which stops
  /// listening before the answer is in: a session restored on an install
  /// updating into this version is still there underneath.
  Future<void> _signOut() async {
    if (Firebase.apps.isEmpty) return;
    final AuthService auth = _ref.read(authServiceProvider);
    if (auth.user != null) await auth.signOut();
  }

  Future<void> setCollection({required bool usage, required bool crashes}) =>
      _save((AppSettings s) =>
          s.copyWith(shareUsage: usage, sendCrashReports: crashes));

  Future<void> setShareUsage(bool value) =>
      _save((AppSettings s) => s.copyWith(shareUsage: value));

  Future<void> setSendCrashReports(bool value) =>
      _save((AppSettings s) => s.copyWith(sendCrashReports: value));
}
