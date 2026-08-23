import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// A course you are enrolled in. Classes hang off a subject, and attendance is
/// aggregated per subject.
@immutable
class Subject {
  const Subject({
    this.id,
    required this.name,
    this.code,
    this.teacher,
    required this.colorValue,
    this.targetPercent,
    this.categoryId,
    this.createdAt,
    this.priorHeld = 0,
    this.priorAttended = 0,
    this.expectedTotal,
  });

  final int? id;
  final String name;
  final String? code;
  final String? teacher;
  final int colorValue;

  /// Per-subject attendance requirement. When null the global target applies.
  final double? targetPercent;

  /// The [ClassCategory] this subject belongs to, which supplies the default
  /// class length. Null means the global default applies.
  final int? categoryId;

  final DateTime? createdAt;

  /// Classes held before this app started counting, and how many were
  /// attended. Carried rather than invented as records: they have no dates.
  final int priorHeld;
  final int priorAttended;

  /// Classes this subject holds all term. Null leaves the projection to
  /// [ScheduleEngine], which can only work from the slots.
  final int? expectedTotal;

  Color get color => Color(colorValue);

  /// Two-letter monogram used on avatars, e.g. "Data Structures" -> "DS".
  String get initials {
    final List<String> words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first
          .substring(0, words.first.length >= 2 ? 2 : 1)
          .toUpperCase();
    }
    return (words[0][0] + words[1][0]).toUpperCase();
  }

  Subject copyWith({
    int? id,
    String? name,
    String? code,
    String? teacher,
    int? colorValue,
    double? targetPercent,
    bool clearTargetPercent = false,
    int? categoryId,
    bool clearCategory = false,
    DateTime? createdAt,
    int? priorHeld,
    int? priorAttended,
    int? expectedTotal,
    bool clearExpectedTotal = false,
  }) {
    return Subject(
      id: id ?? this.id,
      name: name ?? this.name,
      code: code ?? this.code,
      teacher: teacher ?? this.teacher,
      colorValue: colorValue ?? this.colorValue,
      targetPercent:
          clearTargetPercent ? null : (targetPercent ?? this.targetPercent),
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      createdAt: createdAt ?? this.createdAt,
      priorHeld: priorHeld ?? this.priorHeld,
      priorAttended: priorAttended ?? this.priorAttended,
      expectedTotal:
          clearExpectedTotal ? null : (expectedTotal ?? this.expectedTotal),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'code': code,
        'teacher': teacher,
        'color': colorValue,
        'target_percent': targetPercent,
        'category_id': categoryId,
        'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
        'prior_held': priorHeld,
        'prior_attended': priorAttended,
        'expected_total': expectedTotal,
      };

  factory Subject.fromMap(Map<String, Object?> map) {
    final int held = math.max(0, (map['prior_held'] as num?)?.toInt() ?? 0);
    final int attended =
        math.max(0, (map['prior_attended'] as num?)?.toInt() ?? 0);
    return Subject(
      id: map['id'] as int?,
      name: (map['name'] as String?) ?? '',
      code: map['code'] as String?,
      teacher: map['teacher'] as String?,
      colorValue: (map['color'] as int?) ?? AppColors.defaultSubjectColor,
      targetPercent: (map['target_percent'] as num?)?.toDouble(),
      categoryId: map['category_id'] as int?,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      priorHeld: held,
      // A hand-edited backup must not attend more classes than it held.
      priorAttended: math.min(attended, held),
      expectedTotal: (map['expected_total'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Subject && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
