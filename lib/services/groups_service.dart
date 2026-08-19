import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/group.dart';
import 'pgups_cache_service.dart';
import 'pgups_http_client.dart';

/// Fetches and parses the group listing page:
/// https://rasp.pgups.ru/schedule/group
///
/// The page is a flat sequence of headings + link lists (not deeply nested),
/// roughly:
///   <h3>Очная форма</h3>
///     <h3 id="course_1">1 Курс</h3>   (or an anchor with that id nearby)
///       <h5>Faculty name</h5>
///         <a href="/schedule/group/123...">АТ-501</a> <a ...>...</a>
///       <h5>Next faculty</h5>
///         ...
///   <h3>Заочная форма</h3>
///     ...
///
/// Because exact tag levels can vary, we walk the DOM in document order and
/// react to *text content* / *id attributes* rather than specific tag names,
/// which makes this resilient to small markup changes.
class GroupsFetchException implements Exception {
  final String? bodySnippet;
  GroupsFetchException([this.bodySnippet]);
  @override
  String toString() {
    final s = bodySnippet;
    if (s == null || s.isEmpty) {
      return 'Не удалось загрузить список групп (пустой ответ сайта)';
    }
    final trimmed = s.length > 300 ? '${s.substring(0, 300)}…' : s;
    return 'Не удалось загрузить список групп (страница без списка групп). '
        'Получено: $trimmed';
  }
}

class GroupsService {
  static const _listUrl = 'https://rasp.pgups.ru/schedule/group';

  static final RegExp _groupHref =
      RegExp(r'/schedule/group/(\d+)\s*$');
  static final RegExp _courseId =
      RegExp(r'^course(_halftime2?)?_(\d+)$');

  /// Cache-first by default: if a cached copy of the group list exists,
  /// it's returned immediately with **no network / WebView request at
  /// all**. Pass [forceRefresh] (used for pull-to-refresh) to bypass the
  /// cache and hit the network, refreshing the cache on success.
  Future<List<Group>> fetchGroups({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await PgupsCacheService.instance.read(_listUrl);
      if (cached != null) {
        final parsed = parseGroups(cached);
        // Guards against a *previous* run having cached a bad/empty
        // parse (see below) before this check existed; treat it the
        // same as "nothing cached" so we fall through to the network
        // instead of being stuck on an empty list forever.
        if (parsed.isNotEmpty) return parsed;
      }
    }

    try {
      return await _fetchFromNetwork();
    } catch (e) {
      // Network attempt (incl. retries) failed or came back empty — fall
      // back to the cache one more time (even a stale/empty one is a
      // last resort), otherwise surface the error.
      final cached = await PgupsCacheService.instance.read(_listUrl);
      if (cached != null) {
        final parsed = parseGroups(cached);
        if (parsed.isNotEmpty) return parsed;
      }
      rethrow;
    }
  }

  /// A cold app start can race the WebView's native platform view, which
  /// isn't guaranteed to be ready the instant the widget tree mounts — the
  /// very first request can come back with a half-loaded/empty page even
  /// though the site itself is fine. A couple of short retries absorbs
  /// that race so the user isn't stuck on an empty screen forever.
  Future<List<Group>> _fetchFromNetwork() async {
    const maxAttempts = 3;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final res = await PgupsHttpClient.instance.get(_listUrl);
        if (res.statusCode != 200) {
          throw Exception(
              'Не удалось загрузить список групп (HTTP ${res.statusCode})');
        }
        final parsed = parseGroups(res.body);
        if (parsed.isEmpty) {
          // Don't cache an empty/unparseable result — that would poison
          // the cache and permanently hide a previously-working list.
          throw GroupsFetchException(res.body);
        }
        await PgupsCacheService.instance.write(_listUrl, res.body);
        return parsed;
      } catch (e) {
        lastError = e;
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
    }
    throw lastError ?? GroupsFetchException();
  }

  /// Exposed separately so it can be unit-tested / re-used on cached HTML.
  List<Group> parseGroups(String htmlBody) {
    final doc = html_parser.parse(htmlBody);
    final body = doc.body;
    if (body == null) return [];

    final groups = <Group>[];

    String currentForm = 'Очная форма';
    int currentCourse = 1;
    String currentFaculty = '';

    void visit(Node node) {
      if (node is Element) {
        final text = node.text.trim();

        // Update current "form" (очная/заочная/очно-заочная) when we hit a
        // heading whose *own* text matches one of the known labels exactly.
        if (text == 'Очная форма' ||
            text == 'Заочная форма' ||
            text == 'Очно-заочная форма') {
          currentForm = text;
        }

        // Update current course number via id="course_N" /
        // id="course_halftime_N" / id="course_halftime2_N" on any element.
        final id = node.attributes['id'] ?? '';
        if (id.isNotEmpty) {
          final m = _courseId.firstMatch(id);
          if (m != null) {
            currentCourse = int.tryParse(m.group(2) ?? '') ?? currentCourse;
          }
        }

        // Faculty sub-headings: short heading-like tags (h3-h6) that are not
        // one of the form labels and don't look like a course TOC entry.
        if (RegExp(r'^h[3-6]$').hasMatch(node.localName ?? '') &&
            text.isNotEmpty &&
            text != currentForm &&
            !RegExp(r'^\d+\s*Курс$', caseSensitive: false).hasMatch(text)) {
          currentFaculty = text;
        }

        // A group link.
        final href = node.attributes['href'] ?? '';
        final hrefMatch = _groupHref.firstMatch(href);
        if (node.localName == 'a' && hrefMatch != null) {
          final id0 = hrefMatch.group(1)!;
          final name = node.text.trim();
          if (name.isNotEmpty) {
            groups.add(Group(
              id: id0,
              name: name,
              faculty: currentFaculty,
              course: currentCourse,
              form: currentForm,
            ));
          }
        }
      }
      for (final child in node.nodes) {
        visit(child);
      }
    }

    visit(body);

    // De-duplicate (the site repeats заочная/очно-заочная group lists in a
    // second "Другие расписания"-adjacent block further down the page).
    final seen = <String>{};
    final deduped = <Group>[];
    for (final g in groups) {
      final key = '${g.id}_${g.form}';
      if (seen.add(key)) deduped.add(g);
    }

    return deduped;
  }
}
