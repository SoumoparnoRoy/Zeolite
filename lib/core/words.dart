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
      '$value ${value == 1 ? singular : (plural ?? '${singular}s')}';
}
