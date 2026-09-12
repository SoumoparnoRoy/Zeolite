import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// How a single class occurrence turned out.
///
/// Only [present] and [absent] count towards the attendance percentage.
/// [cancelled] means the class did not take place, so it is excluded from both
/// the numerator and the denominator.
enum AttendanceStatus {
  present,
  absent,
  cancelled;

  static AttendanceStatus? fromName(String? value) {
    if (value == null) return null;
    for (final AttendanceStatus status in AttendanceStatus.values) {
      if (status.name == value) return status;
    }
    return null;
  }

  /// Whether this occurrence is included in the attendance denominator.
  bool get countsTowardsTotal => this != AttendanceStatus.cancelled;

  /// Whether this occurrence is included in the attendance numerator.
  bool get countsAsAttended => this == AttendanceStatus.present;

  String get label => switch (this) {
        AttendanceStatus.present => 'Present',
        AttendanceStatus.absent => 'Absent',
        AttendanceStatus.cancelled => 'Cancelled',
      };

  String get shortLabel => switch (this) {
        AttendanceStatus.present => '✓',
        AttendanceStatus.absent => '✕',
        AttendanceStatus.cancelled => 'O',
      };

  IconData get icon => switch (this) {
        AttendanceStatus.present => Icons.check_rounded,
        AttendanceStatus.absent => Icons.close_rounded,
        AttendanceStatus.cancelled => Icons.block_rounded,
      };

  /// Takes the palette rather than reading a global, because the status
  /// colours differ between light and dark — the dark green is too pale to
  /// read on a white card.
  Color colorIn(AppPalette palette) => switch (this) {
        AttendanceStatus.present => palette.present,
        AttendanceStatus.absent => palette.absent,
        AttendanceStatus.cancelled => palette.cancelled,
      };
}
