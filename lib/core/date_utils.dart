/// Date and time helpers.
///
/// Zeolite stores every calendar date as a *local midnight* [DateTime] and
/// every clock time as "minutes since midnight". Keeping both normalised means
/// comparisons, map keys and database round-trips never suffer from stray
/// hours, DST shifts or timezone drift.
library;

import 'dart:math' as math;

const List<String> kWeekdayNamesShort = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> kWeekdayNamesLong = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const List<String> kMonthNamesShort = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<String> kMonthNamesLong = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

class Dates {
  const Dates._();

  /// Strips the time component, returning local midnight of [date].
  static DateTime dayOf(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static DateTime today() => dayOf(DateTime.now());

  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// A stable integer key for a calendar day, e.g. 2026-08-11 -> 20260811.
  ///
  /// Used as a map key and as the database representation of a date. Unlike a
  /// millisecond epoch it is immune to DST and timezone changes.
  static int keyOf(DateTime date) =>
      date.year * 10000 + date.month * 100 + date.day;

  static DateTime fromKey(int key) =>
      DateTime(key ~/ 10000, (key ~/ 100) % 100, key % 100);

  /// Monday of the week containing [date].
  static DateTime startOfWeek(DateTime date) {
    final DateTime d = dayOf(date);
    return d.subtract(Duration(days: d.weekday - DateTime.monday));
  }

  static DateTime addDays(DateTime date, int days) {
    final DateTime d = dayOf(date);
    // Constructing directly (rather than Duration arithmetic) keeps the result
    // at exact local midnight even across daylight-saving boundaries.
    return DateTime(d.year, d.month, d.day + days);
  }

  /// Whole days from [from] to [to], ignoring time of day.
  static int daysBetween(DateTime from, DateTime to) {
    final DateTime a = dayOf(from);
    final DateTime b = dayOf(to);
    return (b.difference(a).inHours / 24).round();
  }

  static bool isWithin(DateTime date, DateTime start, DateTime end) {
    final int k = keyOf(date);
    return k >= keyOf(start) && k <= keyOf(end);
  }

  static String weekdayShort(DateTime date) =>
      kWeekdayNamesShort[date.weekday - 1];

  static String weekdayLong(DateTime date) =>
      kWeekdayNamesLong[date.weekday - 1];

  /// e.g. "Tue, 11 Aug"
  static String formatDayMonth(DateTime date) =>
      '${weekdayShort(date)}, ${date.day} ${kMonthNamesShort[date.month - 1]}';

  /// e.g. "11 Aug 2026"
  static String formatFull(DateTime date) =>
      '${date.day} ${kMonthNamesShort[date.month - 1]} ${date.year}';

  /// e.g. "August 2026"
  static String formatMonthYear(DateTime date) =>
      '${kMonthNamesLong[date.month - 1]} ${date.year}';

  /// A friendly label for dates near today.
  static String relativeLabel(DateTime date) {
    final int diff = daysBetween(today(), date);
    switch (diff) {
      case 0:
        return 'Today';
      case 1:
        return 'Tomorrow';
      case -1:
        return 'Yesterday';
      default:
        return formatDayMonth(date);
    }
  }
}

class Clock {
  const Clock._();

  static const int minutesPerDay = 24 * 60;

  static int toMinutes(int hour, int minute) => hour * 60 + minute;

  static int hourOf(int minutes) => minutes ~/ 60;

  static int minuteOf(int minutes) => minutes % 60;

  /// The end time implied by a class starting at [startMinutes] and running
  /// for [durationMinutes]. Never returns an end at or before the start, and
  /// never spills past midnight — a class cannot straddle two days here,
  /// because attendance is keyed by a single date.
  static int endFromStart(int startMinutes, int durationMinutes) {
    const int lastMinute = minutesPerDay - 1;
    if (startMinutes >= lastMinute) return lastMinute;
    // A late enough start leaves less than the five-minute floor before
    // midnight, so the floor itself has to be clamped or the range inverts.
    final int earliest = math.min(startMinutes + 5, lastMinute);
    return (startMinutes + durationMinutes).clamp(earliest, lastMinute);
  }

  static int nowInMinutes() {
    final DateTime now = DateTime.now();
    return now.hour * 60 + now.minute;
  }

  /// Formats minutes-since-midnight as "9:05 AM" / "14:05" depending on
  /// [use24Hour].
  static String format(int minutes, {bool use24Hour = false}) {
    final int m = minutes.clamp(0, minutesPerDay - 1);
    final int h = m ~/ 60;
    final int mm = m % 60;
    final String two = mm.toString().padLeft(2, '0');
    if (use24Hour) {
      return '${h.toString().padLeft(2, '0')}:$two';
    }
    final String suffix = h < 12 ? 'AM' : 'PM';
    int display = h % 12;
    if (display == 0) display = 12;
    return '$display:$two $suffix';
  }

  /// "9:00 AM – 10:30 AM"
  static String formatRange(
    int startMinutes,
    int endMinutes, {
    bool use24Hour = false,
  }) {
    return '${format(startMinutes, use24Hour: use24Hour)} – '
        '${format(endMinutes, use24Hour: use24Hour)}';
  }

  /// "1h 30m", "45m"
  static String formatDuration(int minutes) {
    final int m = minutes.abs();
    final int h = m ~/ 60;
    final int rem = m % 60;
    if (h == 0) return '${rem}m';
    if (rem == 0) return '${h}h';
    return '${h}h ${rem}m';
  }
}
