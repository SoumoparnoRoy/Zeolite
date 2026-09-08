import 'package:flutter/foundation.dart';

/// A label you can attach to an attendance mark — "Proxy", "Online", "Makeup".
///
/// Separate from [AttendanceStatus] on purpose: the three statuses decide
/// whether a class counts and the maths needs exactly three of them. A tag
/// carries no arithmetic. Unlike [Room] it is referenced by id, since a tag is
/// picked rather than typed and has to survive being renamed.
@immutable
class Tag {
  const Tag({
    this.id,
    required this.name,
    this.position = 0,
    this.createdAt,
  });

  final int? id;
  final String name;

  /// Kept in the order they were added rather than alphabetically, like rooms.
  final int position;

  final DateTime? createdAt;

  Tag copyWith({int? id, String? name, int? position, DateTime? createdAt}) {
    return Tag(
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
        if (createdAt != null) 'created_at': createdAt!.millisecondsSinceEpoch,
      };

  factory Tag.fromMap(Map<String, Object?> map) {
    return Tag(
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
      identical(this, other) || (other is Tag && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
