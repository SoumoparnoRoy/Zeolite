/// Number-to-words for headline copy, so "Two classes to spare" does not
/// compete with the "94%" beside it. Falls back to digits past ten, where the
/// word is longer than the figure.
class Words {
  const Words._();

  static const List<String> _units = <String>[
    'No',
    'One',
    'Two',
    'Three',
    'Four',
    'Five',
    'Six',
    'Seven',
    'Eight',
    'Nine',
    'Ten',
  ];

  /// Capitalised, for the start of a headline.
  static String count(int value) =>
      value >= 0 && value < _units.length ? _units[value] : '$value';

  /// Mid-sentence.
  static String lower(int value) {
    final String word = count(value);
    return value >= 0 && value < _units.length ? word.toLowerCase() : word;
  }

  /// `1 class` / `4 classes`, for anywhere a figure is wanted.
  static String plural(int value, String singular, [String? plural]) =>
      '$value ${noun(value, singular, plural)}';

  /// `75%`, for what is set rather than measured: targets and how far the
  /// term has run. Rounded half away from zero.
  static String percent(num value) => '${value.round()}%';

  /// Attendance as measured, to two places: `76.42%`. Cut rather than
  /// rounded, so a figure short of its target never reads as reaching it
  /// (74.996% is 74.99%, not 75.00%).
  static String attendance(num percent) => '${attendanceFigure(percent)}%';

  /// [attendance] without the sign, for a header that sets it apart. The
  /// nudge absorbs binary error: 29% is stored as 28.999999999999996.
  static String attendanceFigure(num percent) =>
      ((percent * 100 + 1e-6).floor() / 100).toStringAsFixed(2);

  /// The word alone, where the figure is written some other way or sits
  /// apart from it.
  static String noun(int value, String singular, [String? plural]) =>
      value == 1 ? singular : (plural ?? '${singular}s');
}
