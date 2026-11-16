import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/class_session.dart';

/// Asks Play for its review card once, the first time a whole week of
/// classes has been marked. Play rations the card and says nothing when it
/// holds one back, so "asked" is all that can be recorded.
class ReviewPrompt {
  ReviewPrompt({
    SharedPreferencesAsync? prefs,
    Future<bool> Function()? isAvailable,
    Future<void> Function()? request,
  })  : _givenPrefs = prefs,
        _isAvailable = isAvailable ?? InAppReview.instance.isAvailable,
        _request = request ?? InAppReview.instance.requestReview;

  final SharedPreferencesAsync? _givenPrefs;

  // Opened inside the guard below, so a store that can't be reached can't
  // break the mark that led here.
  late final SharedPreferencesAsync _prefs =
      _givenPrefs ?? SharedPreferencesAsync();
  final Future<bool> Function() _isAvailable;
  final Future<void> Function() _request;

  @visibleForTesting
  static const String askedKey = 'review.asked';

  /// Two marks can both finish a week before the first writes the flag.
  bool _asking = false;

  /// [week] is every class in the week the mark landed in. True only when
  /// this call reached Play without an error.
  Future<bool> afterMark(List<ClassSession> week) async {
    if (week.isEmpty || week.any((ClassSession s) => !s.isMarked)) {
      return false;
    }
    if (_asking) return false;
    _asking = true;
    try {
      if (await _prefs.getBool(askedKey) ?? false) return false;
      // Written first, so a card that fails or never shows still counts.
      await _prefs.setBool(askedKey, true);
      if (await _isAvailable()) await _request();
      return true;
    } on Object {
      // No Play Store or no activity: nothing the student needs to see.
      return false;
    } finally {
      _asking = false;
    }
  }
}
