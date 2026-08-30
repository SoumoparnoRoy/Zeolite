import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';

/// A kind of class — Theory, Lab, Tutorial, Seminar — that the user defines.
///
/// Carries what follows from the kind of class it is: a default length, and
/// how much one of them counts towards attendance. An institution that counts
/// the lab twice says so once here rather than on every slot.
///
/// Named `ClassCategory` rather than `Category` because `package:flutter/
/// foundation.dart` already exports a `Category` annotation.
@immutable
class ClassCategory {
  const ClassCategory({
    this.id,
    required this.name,
    required this.defaultDurationMinutes,
    this.weight = 1,
    this.createdAt,
  });

  final int? id;
  final String name;
  final int defaultDurationMinutes;

  /// Zero counts towards neither side of the percentage.
  final int weight;

  final DateTime? createdAt;

  String get durationLabel => Clock.formatDuration(defaultDurationMinutes);

  ClassCategory copyWith({
    int? id,
    String? name,
    int? defaultDurationMinutes,
    int? weight,
    DateTime? createdAt,
  }) {
    return ClassCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      defaultDurationMinutes:
          defaultDurationMinutes ?? this.defaultDurationMinutes,
      weight: weight ?? this.weight,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'default_minutes': defaultDurationMinutes,
        'weight': weight,
        'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
      };

  factory ClassCategory.fromMap(Map<String, Object?> map) {
    return ClassCategory(
      id: map['id'] as int?,
      name: (map['name'] as String?) ?? '',
      defaultDurationMinutes: (map['default_minutes'] as int?) ?? 60,
      weight: (map['weight'] as int?) ?? 1,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ClassCategory && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
