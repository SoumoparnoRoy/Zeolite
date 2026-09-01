import '../../domain/notion/notion_course.dart';
import '../../domain/notion/notion_mapping.dart';
import '../../domain/notion/notion_properties.dart';
import 'notion_client.dart';

/// Keeps one page per subject in the Courses table, and hands back the page id
/// a mark's `Course` relation has to point at.
///
/// The far side is the source of truth for those ids rather than anything
/// stored on the device: a page is found again by its `Zeolite ID`, exactly as
/// a mark is, so deleting a course page in Notion heals on the next run
/// instead of leaving a link pointing at nothing.
class NotionCoursesWriter {
  NotionCoursesWriter({
    required NotionClient client,
    required NotionCourses courses,
  })  : _client = client,
        _courses = courses;

  final NotionClient _client;
  final NotionCourses _courses;

  /// Loaded once and reused for the rest of the run: a timetable of eight
  /// subjects would otherwise query the same table eight times.
  Map<String, _Page>? _pages;

  /// Dropped between runs so a page made in Notion since is seen.
  void forget() => _pages = null;

  /// The page id for [course], creating or correcting the page as needed, or
  /// null when the table cannot be read or written. Null is not fatal — the
  /// caller writes the mark without a relation rather than not at all.
  Future<String?> pageIdFor(NotionCourse course) async {
    final Map<String, _Page>? pages = await _load();
    if (pages == null) return null;

    final _Page? existing = pages[course.uuid];
    if (existing == null) return _create(course, pages);

    // A renamed subject, or prior counts edited after the page was made.
    if (existing.course != course) {
      final NotionResult result = await _client.updatePage(
        existing.id,
        _propertiesFor(course),
      );
      if (result.ok) pages[course.uuid] = _Page(existing.id, course);
    }
    return existing.id;
  }

  Future<String?> _create(NotionCourse course, Map<String, _Page> pages) async {
    final NotionResult result = await _client.createPage(
      dataSourceId: _courses.dataSourceId,
      properties: _propertiesFor(course),
    );
    final String? id = result.body?['id'] as String?;
    if (!result.ok || id == null) return null;
    pages[course.uuid] = _Page(id, course);
    return id;
  }

  Future<Map<String, _Page>?> _load() async {
    final Map<String, _Page>? cached = _pages;
    if (cached != null) return cached;
    if (!_courses.isComplete) return null;

    final NotionRows rows = await _client.queryAllPages(_courses.dataSourceId);
    if (!rows.ok) return null;

    final Map<String, _Page> found = <String, _Page>{};
    for (final Map<String, Object?> page in rows.pages) {
      final String? id = page['id'] as String?;
      final Map<String, Object?> properties =
          (page['properties'] as Map<String, Object?>?) ?? <String, Object?>{};
      final String? uuid = NotionProperties.plainTextOf(
        NotionProperties.valueOf(properties, _field(NotionCourseField.key)),
      );
      if (id == null || uuid == null || uuid.isEmpty) continue;

      found[uuid] = _Page(
        id,
        NotionCourse(
          uuid: uuid,
          name: NotionProperties.plainTextOf(
                NotionProperties.valueOf(
                  properties,
                  _field(NotionCourseField.name),
                ),
              ) ??
              '',
          priorHeld: _numberOf(properties, NotionCourseField.priorHeld),
          priorAttended:
              _numberOf(properties, NotionCourseField.priorAttended),
        ),
      );
    }
    _pages = found;
    return found;
  }

  int _numberOf(Map<String, Object?> properties, NotionCourseField field) {
    final NotionProperty? property = _field(field);
    if (property == null) return 0;
    return NotionProperties.numberOf(
          NotionProperties.valueOf(properties, property),
        )?.round() ??
        0;
  }

  Map<String, Object?> _propertiesFor(NotionCourse course) {
    final Map<String, Object?> out = <String, Object?>{};
    void put(NotionCourseField field, Object? value) {
      final NotionProperty? property = _field(field);
      if (property != null && value != null) out[property.id] = value;
    }

    put(NotionCourseField.name, NotionProperties.titleOf(course.name));
    put(NotionCourseField.key, NotionProperties.textOf(course.uuid));
    // Written even when zero: a page made before the user filled these in
    // would otherwise keep whatever Notion had, and the dashboard's formula
    // adds them to the rollups.
    put(NotionCourseField.priorHeld,
        <String, Object?>{'number': course.priorHeld});
    put(NotionCourseField.priorAttended,
        <String, Object?>{'number': course.priorAttended});
    return out;
  }

  NotionProperty? _field(NotionCourseField field) => _courses.fields[field];
}

class _Page {
  const _Page(this.id, this.course);

  final String id;
  final NotionCourse course;
}
