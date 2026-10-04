import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/app.dart';

/// Stats is two pages of the pager but one tab of the bar.
void main() {
  int page(String name) => RootShell.pageNames.indexOf(name);
  int tab(String name) => RootShell.tabNames.indexOf(name);

  test('both Stats pages light the Stats tab, and the rest keep their own', () {
    expect(RootShell.tabOfPage(page('stats')), tab('stats'));
    expect(RootShell.tabOfPage(page('counts')), tab('stats'));
    expect(RootShell.tabOfPage(page('timetable')), tab('timetable'));
    expect(RootShell.tabOfPage(page('settings')), tab('settings'));
  });

  test('the Stats tab goes back to whichever page was last shown', () {
    for (final String last in <String>['stats', 'counts']) {
      expect(
        RootShell.pageOfTab(tab('stats'), statsPage: page(last)),
        page(last),
      );
    }
    expect(
      RootShell.pageOfTab(tab('settings'), statsPage: page('counts')),
      page('settings'),
    );
  });

  test('Counts sits between Overview and Settings, so a swipe reaches it', () {
    expect(page('counts'), page('stats') + 1);
    expect(page('settings'), page('counts') + 1);
  });
}
