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
    this.priorHeld = 0,
    this.priorAttended = 0,
  });

  final String uuid;
  final String name;

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
      other.priorHeld == priorHeld &&
      other.priorAttended == priorAttended;

  @override
  int get hashCode => Object.hash(uuid, name, priorHeld, priorAttended);
}
