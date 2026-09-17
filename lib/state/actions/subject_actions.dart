import 'dart:async';

import '../../data/db/zeolite_repository.dart';
import '../../data/models/class_category.dart';
import '../../data/models/room.dart';
import '../../data/models/subject.dart';
import '../../data/models/tag.dart';
import '../providers.dart';

import 'action_core.dart';

/// Subjects and the lists they are filed under: categories, rooms and tags.
class SubjectActions {
  SubjectActions(this._core);

  final ActionCore _core;

  // categories -------------------------------------------------------------

  Future<int> addCategory(ClassCategory category) async {
    final int id = await _core.repo.insertCategory(category);
    await _core.refresh();
    return id;
  }

  Future<void> updateCategory(ClassCategory category) async {
    await _core.repo.updateCategory(category);
    await _core.refresh();
  }

  /// Subjects in a deleted category keep all their data and fall back to the
  /// global default class length.
  Future<void> deleteCategory(int id) async {
    await _core.repo.deleteCategory(id);
    await _core.refresh();
  }

  Future<int> countSubjectsInCategory(int id) =>
      _core.repo.countSubjectsInCategory(id);

  // rooms ------------------------------------------------------------------

  Future<int> addRoom(Room room) async {
    final int id = await _core.repo.insertRoom(room);
    await _core.refresh();
    return id;
  }

  Future<void> updateRoom(Room room) async {
    await _core.repo.updateRoom(room);
    await _core.refresh();
  }

  /// Only forgets the suggestion. Classes already assigned this room keep it,
  /// because the room is stored on the class as text.
  Future<void> deleteRoom(int id) async {
    await _core.repo.deleteRoom(id);
    await _core.refresh();
  }

  // subjects ---------------------------------------------------------------

  Future<int> addSubject(Subject subject) async {
    final int id = await _core.repo.insertSubject(subject);
    await _core.refresh();
    return id;
  }

  Future<void> updateSubject(Subject subject) async {
    await _core.repo.updateSubject(subject);
    await _core.refresh();
  }

  Future<void> deleteSubject(int id) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.deleteSubject(id);
    await _core.refresh();
    _core.arm(before);
  }

  // tags --------------------------------------------------------------------

  Future<int> addTag(Tag tag) async {
    final int id = await _core.repo.insertTag(tag);
    await _core.refresh();
    return id;
  }

  Future<void> updateTag(Tag tag) async {
    await _core.repo.updateTag(tag);
    await _core.refresh();
  }

  Future<void> deleteTag(int id) async {
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.deleteTag(id);
    await _core.refresh();
    _core.arm(before);
  }

  Future<int> countMarksWithTag(int id) => _core.repo.countMarksWithTag(id);
}
