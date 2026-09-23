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

  /// Pages with no key, by lowercased title: courses somebody made by hand.
  Map<String, List<_Page>> _unkeyed = <String, List<_Page>>{};

  /// Dropped between runs so a page made in Notion since is seen.
  void forget() {
    _pages = null;
    _unkeyed = <String, List<_Page>>{};
  }

  /// Starts the key of a page the app took over rather than made. It lives in
  /// the table, not on the device, so a reinstall still knows whose values
  /// the page holds.
  static const String adoptedMark = '~';

  /// The page id for [course], creating or correcting the page as needed, or
  /// null when the table cannot be read or written. Null is not fatal — the
  /// caller writes the mark without a relation rather than not at all.
  Future<String?> pageIdFor(NotionCourse course) async {
    final Map<String, _Page>? pages = await _load();
    if (pages == null) return null;

    _Page? existing = pages[course.uuid];
    if (existing == null) {
      final String name = _nameKey(course.name);
      final List<_Page> named = _unkeyed[name] ?? const <_Page>[];
      // Two pages of one name leave no way to tell which the classes meant,
      // and a third page of the app's own would only add to it.
      if (named.length > 1) return null;
      if (named.isEmpty) {
        return _courseOfLab(course.name, pages)?.id ??
            _create(course, pages);
      }
      _unkeyed.remove(name);
      existing = pages[course.uuid] = named.single;
    }

    // Filled rather than overwritten on a page taken over: an empty field here
    // is one the app never had, not one somebody cleared.
    final NotionCourse wanted =
        existing.adopted ? _filled(course, existing.course) : course;
    if (existing.course != wanted) {
      final NotionResult result = await _client.updatePage(
        existing.id,
        _propertiesFor(wanted, adopted: existing.adopted),
      );
      if (result.ok) {
        pages[course.uuid] =
            _Page(existing.id, wanted, adopted: existing.adopted);
      }
    }
    return existing.id;
  }

  /// Whether any of [pageIds] is a page the table still holds. True when the
  /// table cannot be read, so nothing is repointed on a guess.
  Future<bool> holdsAny(List<String> pageIds) async {
    final Map<String, _Page>? pages = await _load();
    if (pages == null) return true;
    final Set<String> held = <String>{
      for (final _Page page in pages.values) page.id,
      for (final List<_Page> named in _unkeyed.values)
        for (final _Page page in named) page.id,
    };
    return pageIds.any(held.contains);
  }

  static NotionCourse _filled(NotionCourse ours, NotionCourse theirs) {
    String? text(String? mine, String? other) =>
        (mine == null || mine.isEmpty) ? other : mine;
    return NotionCourse(
      uuid: ours.uuid,
      name: ours.name,
      code: text(ours.code, theirs.code),
      teacher: text(ours.teacher, theirs.teacher),
      targetPercent: ours.targetPercent ?? theirs.targetPercent,
      expectedTotal: ours.expectedTotal ?? theirs.expectedTotal,
      priorHeld: ours.priorHeld == 0 ? theirs.priorHeld : ours.priorHeld,
      priorAttended:
          ours.priorAttended == 0 ? theirs.priorAttended : ours.priorAttended,
    );
  }

  static String _nameKey(String name) => name.trim().toLowerCase();

  /// The import names a practical `X Lab` in a table whose labs belong to
  /// course X, so a table somebody kept has no page for it. Only a page of
  /// theirs is used: one the app made keeps a lab subject on its own page.
  _Page? _courseOfLab(String name, Map<String, _Page> pages) {
    final List<String> words = name.trim().split(RegExp(r'\s+'));
    if (words.length < 2 || words.last.toLowerCase() != 'lab') return null;
    final String course =
        _nameKey(words.sublist(0, words.length - 1).join(' '));

    final List<_Page> unkeyed = _unkeyed[course] ?? const <_Page>[];
    if (unkeyed.length == 1) return unkeyed.single;
    for (final _Page page in pages.values) {
      if (page.adopted && _nameKey(page.course.name) == course) return page;
    }
    return null;
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
    final Map<String, List<_Page>> unkeyed = <String, List<_Page>>{};
    for (final Map<String, Object?> page in rows.pages) {
      final String? id = page['id'] as String?;
      if (id == null) continue;
      final Map<String, Object?> properties =
          (page['properties'] as Map<String, Object?>?) ?? <String, Object?>{};
      final String key = NotionProperties.plainTextOf(
            NotionProperties.valueOf(properties, _field(NotionCourseField.key)),
          ) ??
          '';
      final bool adopted = key.startsWith(adoptedMark);
      final String uuid = adopted ? key.substring(adoptedMark.length) : key;

      // An empty uuid never equals a subject's, so the first correction of an
      // adopted page writes its key along with everything else.
      final _Page read = _Page(
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
          code: NotionProperties.plainTextOf(
            NotionProperties.valueOf(
              properties,
              _field(NotionCourseField.code),
            ),
          ),
          teacher: NotionProperties.plainTextOf(
            NotionProperties.valueOf(
              properties,
              _field(NotionCourseField.teacher),
            ),
          ),
          targetPercent: NotionProperties.numberOf(
            NotionProperties.valueOf(
              properties,
              _field(NotionCourseField.targetPercent),
            ),
          )?.toDouble(),
          expectedTotal: NotionProperties.numberOf(
            NotionProperties.valueOf(
              properties,
              _field(NotionCourseField.expectedTotal),
            ),
          )?.round(),
          priorHeld: _numberOf(properties, NotionCourseField.priorHeld),
          priorAttended:
              _numberOf(properties, NotionCourseField.priorAttended),
        ),
        adopted: adopted || uuid.isEmpty,
      );
      if (uuid.isNotEmpty) {
        found[uuid] = read;
      } else if (read.course.name.trim().isNotEmpty) {
        (unkeyed[_nameKey(read.course.name)] ??= <_Page>[]).add(read);
      }
    }
    _pages = found;
    _unkeyed = unkeyed;
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

  Map<String, Object?> _propertiesFor(
    NotionCourse course, {
    bool adopted = false,
  }) {
    final Map<String, Object?> out = <String, Object?>{};
    void put(NotionCourseField field, Object? value) {
      final NotionProperty? property = _field(field);
      if (property != null && value != null) out[property.id] = value;
    }

    put(NotionCourseField.name, NotionProperties.titleOf(course.name));
    put(
      NotionCourseField.key,
      NotionProperties.textOf(
        adopted ? '$adoptedMark${course.uuid}' : course.uuid,
      ),
    );
    // Written even when empty, so clearing a code in the app clears it there
    // rather than leaving the old one behind.
    put(NotionCourseField.code, NotionProperties.textOf(course.code ?? ''));
    put(NotionCourseField.teacher,
        NotionProperties.textOf(course.teacher ?? ''));
    // Null rather than zero where the student has not set one: a target of 0%
    // and no target at all are different answers.
    put(NotionCourseField.targetPercent,
        <String, Object?>{'number': course.targetPercent});
    put(NotionCourseField.expectedTotal,
        <String, Object?>{'number': course.expectedTotal});
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
  const _Page(this.id, this.course, {this.adopted = false});

  final String id;
  final NotionCourse course;
  final bool adopted;
}
