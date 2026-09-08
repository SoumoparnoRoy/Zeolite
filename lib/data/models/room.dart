import 'package:flutter/foundation.dart';

/// A room number you teach in, saved so it can be picked instead of retyped.
///
/// Deliberately *not* a foreign key on `class_slots`, which keeps storing its
/// room as plain text. The list is a vocabulary, not a relationship: deleting a
/// room cannot orphan a class, a room typed by hand still works, and backups
/// written before this table existed still restore.
@immutable
class Room {
  const Room({
    this.id,
    required this.name,
    this.position = 0,
    this.createdAt,
  });

  final int? id;
  final String name;

  /// Kept in the order the timetable uses them rather than alphabetically.
  final int position;

  /// When this device made the row. Nullable because rows that predate the
  /// v12 column cannot be dated, and the sync ledger reads null as "no claim":
  /// a tombstone for the same name then wins, as it did before.
  final DateTime? createdAt;

  Room copyWith({int? id, String? name, int? position, DateTime? createdAt}) {
    return Room(
      id: id ?? this.id,
      name: name ?? this.name,
      position: position ?? this.position,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'position': position,
        // Left out rather than written null, so updating a row that predates
        // the column does not silently date it to now.
        if (createdAt != null) 'created_at': createdAt!.millisecondsSinceEpoch,
      };

  factory Room.fromMap(Map<String, Object?> map) {
    return Room(
      id: map['id'] as int?,
      name: (map['name'] as String?) ?? '',
      position: (map['position'] as int?) ?? 0,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Room && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
