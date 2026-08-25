import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/features/today/session_card.dart';

const Subject _signals = Subject(id: 1, name: 'Signal Theory', colorValue: 0xFF7C6BFF);
const Subject _control = Subject(id: 2, name: 'Control Systems', colorValue: 0xFF3DD68C);

ClassSession _session(Subject subject, {AttendanceStatus? status}) {
  final DateTime date = DateTime(2026, 8, 26);
  return ClassSession(
    subject: subject,
    date: date,
    startMinutes: 540,
    endMinutes: 600,
    slotId: subject.id,
    record: status == null
        ? null
        : AttendanceRecord(
            subjectId: subject.id!,
            date: date,
            startMinutes: 540,
            status: status,
          ),
  );
}

Widget _host(SessionCard card) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: card)),
    );

/// The rule itself: the only gradient-filled box in a card.
LinearGradient _spineGradient(WidgetTester tester) {
  final Iterable<DecoratedBox> boxes =
      tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
  final BoxDecoration decoration = boxes
      .map((DecoratedBox b) => b.decoration as BoxDecoration)
      .firstWhere((BoxDecoration d) => d.gradient != null);
  return decoration.gradient! as LinearGradient;
}

void main() {
  testWidgets('a card followed by another hands its line to that colour',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        SessionCard(
          session: _session(_signals),
          use24Hour: false,
          onMark: (AttendanceStatus _) {},
          nextColor: _control.color,
        ),
      ),
    );

    final LinearGradient gradient = _spineGradient(tester);
    expect(gradient.colors.first, _signals.color);
    expect(gradient.colors.last, _control.color);
    // Held, then turned over — a two-stop blend would smear the whole card.
    expect(gradient.colors, hasLength(3));
    expect(gradient.stops!.first, 0);
    expect(gradient.stops![1], greaterThan(0.5));
  });

  testWidgets('the last card fades out instead of blending',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        SessionCard(
          session: _session(_signals),
          use24Hour: false,
          onMark: (AttendanceStatus _) {},
        ),
      ),
    );

    final LinearGradient gradient = _spineGradient(tester);
    expect(gradient.colors.first, _signals.color);
    expect(gradient.colors.last.a, lessThan(0.2));
  });

  testWidgets('a cancelled class greys the line for the card above it too',
      (WidgetTester tester) async {
    const AppPalette palette = AppPalette.dark;
    expect(
      SessionCard.spineColorOf(
        _session(_control, status: AttendanceStatus.cancelled),
        palette,
      ),
      palette.textFaint,
    );
    expect(
      SessionCard.spineColorOf(_session(_control), palette),
      _control.color,
    );
  });
}
