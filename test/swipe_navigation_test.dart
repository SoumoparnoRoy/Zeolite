import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/features/today/today_screen.dart';
import 'package:zeolite/state/providers.dart';

/// A Monday, so the week the grid pages by starts where the origin does.
final DateTime _origin = DateTime(2026, 8, 31);

int _page(HomeView view, DateTime date) =>
    TodayScreen.pageFor(view, _origin, date);

DateTime _date(HomeView view, int page) =>
    TodayScreen.dateForPage(view, _origin, page);

void main() {
  group('the home pager', () {
    test('the day view moves a day at a time', () {
      expect(_page(HomeView.day, _origin), TodayScreen.basePage);
      expect(_page(HomeView.day, DateTime(2026, 9, 2)),
          TodayScreen.basePage + 2);
      expect(_date(HomeView.day, TodayScreen.basePage + 2),
          DateTime(2026, 9, 2));
    });

    test('the grid moves a week, since a day there shows the same block', () {
      expect(_page(HomeView.grid, DateTime(2026, 9, 7)),
          TodayScreen.basePage + 1);
      expect(_date(HomeView.grid, TodayScreen.basePage + 1),
          DateTime(2026, 9, 7));
    });

    test('every day of a week sits on that week\'s page', () {
      for (int i = 0; i < 7; i++) {
        expect(_page(HomeView.grid, Dates.addDays(_origin, 7 + i)),
            TodayScreen.basePage + 1);
      }
    });

    test('going back past the origin still lands on the right day', () {
      expect(_page(HomeView.day, DateTime(2026, 8, 20)),
          TodayScreen.basePage - 11);
      expect(_date(HomeView.day, TodayScreen.basePage - 11),
          DateTime(2026, 8, 20));
    });
  });
}
