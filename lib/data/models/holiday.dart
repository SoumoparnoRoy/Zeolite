import 'package:flutter/foundation.dart';

import '../../core/date_utils.dart';

/// A day with no classes — a public holiday, a strike, a mid-term break day.
/// Recurring slots do not generate occurrences on these dates.
@immutable
class Holiday {
  const Holiday({
    this.id,
    required this.date,
    required this.name,
    this.createdAt,
  });

  final int? id;
  final DateTime date;
  final String name;

  final DateTime? createdAt;

  Holiday copyWith({
    int? id,
    DateTime? date,
    String? name,
    DateTime? createdAt,
  }) =>
      Holiday(
        id: id ?? this.id,
        date: date ?? this.date,
        name: name ?? this.name,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'date': Dates.keyOf(date),
        'name': name,
        if (createdAt != null) 'created_at': createdAt!.millisecondsSinceEpoch,
      };

  factory Holiday.fromMap(Map<String, Object?> map) => Holiday(
        id: map['id'] as int?,
        date: Dates.fromKey((map['date'] as int?) ?? 19700101),
        name: (map['name'] as String?) ?? 'Holiday',
        createdAt: map['created_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      );
}
