import 'package:flutter/foundation.dart';

/// A subject as the Courses table holds it.
///
/// Its own type rather than [Subject] so the Notion layer does not depend on
/// the database model: what a workspace needs is a name, something to
/// recognise the page by, and the counts that predate the app.
@immutable
class NotionCourse {
  const NotionCourse({
    required this.uuid,
    required this.name,
    this.code,
    this.teacher,
    this.targetPercent,
    this.expectedTotal,
    this.priorHeld = 0,
    this.priorAttended = 0,
  });

  final String uuid;
  final String name;

  /// The university's own code for the course, such as `SUB1`. Null where
  /// the subject has none, which is most of them until someone types one.
  final String? code;

  /// Who teaches it, and the share of classes the student means to attend.
  /// Both are the app's own record of the course rather than of any one class,
  /// which is why they belong on the course page.
  final String? teacher;
  final double? targetPercent;

  /// How many classes the course runs all term, where the student knows. The
  /// dashboard needs it to say anything about classes not yet held.
  final int? expectedTotal;

  /// Classes held and attended before this app was used. They never reach an
  /// attendance row, so a dashboard rolled up from rows alone would disagree
  /// with the app for anyone who carried numbers in.
  final int priorHeld;
  final int priorAttended;

  @override
  bool operator ==(Object other) =>
      other is NotionCourse &&
      other.uuid == uuid &&
      other.name == name &&
      other.code == code &&
      other.teacher == teacher &&
      other.targetPercent == targetPercent &&
      other.expectedTotal == expectedTotal &&
      other.priorHeld == priorHeld &&
      other.priorAttended == priorAttended;

  @override
  int get hashCode => Object.hash(
        uuid,
        name,
        code,
        teacher,
        targetPercent,
        expectedTotal,
        priorHeld,
        priorAttended,
      );
}
