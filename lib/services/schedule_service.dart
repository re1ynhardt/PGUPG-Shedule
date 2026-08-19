import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/lesson.dart';
import 'pgups_cache_service.dart';
import 'pgups_http_client.dart';

/// Parses https://rasp.pgups.ru/schedule/group/{id}[/{subgroupId}]
///
/// Real markup (confirmed from a live page dump), per weekday:
///
///   <div class="d-block d-md-none"><h4>Понедельник</h4></div>
///   <table class="table m-table mb-5">
///     <tr>
///       <td rowspan="N" class="d-none d-md-table-cell"><h4 class="kt-font-dark">
///         <i class="flaticon-more"></i>&nbsp;Понедельник
///       </h4></td>
///       <td>N пара</td>
///       <td> <span>HH:MM &mdash; HH:MM</span>
///            <div class="text-center mt-2"><a class="kt-link">
///              <i .../>&nbsp;ауд. X-XXX</a></div> </td>
///       <td class="align-middle">
///         <div class="mb-2"><span class="mr-1">Предмет</span>
///                            <span class="badge ...">Тип занятия</span></div>
///         <div><a class="kt-link" href=".../teacher/ID">ФИО</a>, ...</div>
///         <!-- OR, when there's no teacher hyperlink: -->
///         доц. Фамилия И.И.
///       </td>
///     </tr>
///     <tr> <!-- subsequent rows: no rowspan td, 3 tds instead of 4 --> ... </tr>
///   </table>
///
/// Empty days render an empty <table class="table m-table mb-5"></table>
/// with no rows at all (weekday name only available from the preceding div).
class ScheduleHttpException implements Exception {
  final int statusCode;
  final String responseBody;
  final Map<String, String> headers;
  ScheduleHttpException(this.statusCode, this.responseBody, this.headers);

  @override
  String toString() => 'Не удалось загрузить расписание (HTTP $statusCode)';
}

class ScheduleFetchException implements Exception {
  @override
  String toString() =>
      'Не удалось загрузить расписание (пустой ответ сайта)';
}

class ScheduleService {
  static const _weekdays = [
    'Понедельник',
    'Вторник',
    'Среда',
    'Четверг',
    'Пятница',
    'Суббота',
    'Воскресенье',
  ];

  static final RegExp _pairNumber = RegExp(r'(\d+)\s*пара');
  static final RegExp _timeRange =
      RegExp(r'(\d{1,2}:\d{2})\s*[-–—―]\s*(\d{1,2}:\d{2})');
  static final RegExp _dateRange =
      RegExp(r'start_date=(\d{4}-\d{2}-\d{2}).*?end_date=(\d{4}-\d{2}-\d{2})');
  static final RegExp _subgroupHref =
      RegExp(r'/schedule/group/\d+/(\d+)(?:\?.*)?$');

  /// Builds the group/subgroup URL, optionally pinned to a specific week.
  static String buildUrl({
    required String groupId,
    String? subgroupId,
    DateTime? weekStart, // any date; Monday of that week is used
  }) {
    final path = subgroupId != null
        ? '/schedule/group/$groupId/$subgroupId'
        : '/schedule/group/$groupId';
    final buffer = StringBuffer('https://rasp.pgups.ru$path');
    if (weekStart != null) {
      final monday = weekStart.subtract(Duration(days: weekStart.weekday - 1));
      final sunday = monday.add(const Duration(days: 6));
      buffer.write('?start_date=${_fmt(monday)}&end_date=${_fmt(sunday)}');
    }
    return buffer.toString();
  }

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Cache-first by default: each exact URL (group + subgroup + week) has
  /// its own cache entry, so a previously viewed day/week always renders
  /// instantly and offline, with **no WebView request**. Pass
  /// [forceRefresh] (used for pull-to-refresh) to bypass the cache and hit
  /// the network, refreshing the cache on success.
  Future<GroupSchedule> fetchSchedule(
    String url,
    String groupName, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = await PgupsCacheService.instance.read(url);
      if (cached != null) {
        final parsed = parseSchedule(cached, groupName);
        // Guards against a *previous* run having cached a broken/blank
        // parse (see below) before this check existed; fall through to
        // the network instead of being stuck on a blank page forever.
        if (parsed.weekLabel != null) return parsed;
      }
    }

    try {
      return await _fetchFromNetwork(url, groupName);
    } catch (e) {
      // Network attempt (incl. retries) failed or came back broken — fall
      // back to the cache one more time (even a stale/broken one is a
      // last resort), otherwise surface the error.
      final cached = await PgupsCacheService.instance.read(url);
      if (cached != null) {
        final parsed = parseSchedule(cached, groupName);
        if (parsed.weekLabel != null) return parsed;
      }
      rethrow;
    }
  }

  /// A cold app start can race the WebView's native platform view, which
  /// isn't guaranteed to be ready the instant the widget tree mounts — the
  /// very first request can come back with a half-loaded/blank page even
  /// though the site itself is fine. A couple of short retries absorbs
  /// that race so the user isn't stuck on a blank screen forever. A real
  /// page always has the "Сейчас: Чет/Нечетная неделя" banner, even on a
  /// day with zero lessons, so its absence means the page itself didn't
  /// load properly (challenge/blank/interstitial page) rather than "no
  /// lessons this week".
  Future<GroupSchedule> _fetchFromNetwork(String url, String groupName) async {
    const maxAttempts = 3;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final res = await PgupsHttpClient.instance.get(url);
        if (res.statusCode != 200) {
          throw ScheduleHttpException(res.statusCode, res.body, res.headers);
        }
        final parsed = parseSchedule(res.body, groupName);
        if (parsed.weekLabel == null) {
          // Don't cache a broken/blank result — that would poison the
          // cache and permanently hide a previously-working schedule.
          throw ScheduleFetchException();
        }
        await PgupsCacheService.instance.write(url, res.body);
        return parsed;
      } catch (e) {
        lastError = e;
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
    }
    throw lastError ?? ScheduleFetchException();
  }

  /// Exposed separately for testing on saved HTML / the debug screen.
  GroupSchedule parseSchedule(String htmlBody, String groupName) {
    final doc = html_parser.parse(htmlBody);
    final body = doc.body;

    // --- week label ("Сейчас: Четная неделя") ---------------------------------
    final weekLabelEl = doc.getElementById('kt_dashboard_daterangepicker_date');
    final weekLabel = weekLabelEl?.text.trim();

    // --- displayed date range, if present in any link on the page ------------
    DateTime? startDate;
    DateTime? endDate;
    final dm = _dateRange.firstMatch(htmlBody);
    if (dm != null) {
      startDate = DateTime.tryParse(dm.group(1)!);
      endDate = DateTime.tryParse(dm.group(2)!);
    }

    // --- subgroups -------------------------------------------------------------
    final subgroups = <Subgroup>[];
    if (body != null) {
      for (final a in body.querySelectorAll('a')) {
        final href = a.attributes['href'] ?? '';
        final m = _subgroupHref.firstMatch(Uri.tryParse(href)?.path ?? href);
        if (m == null) continue;
        final labelMatch = RegExp(r'(\d+)\s*$').firstMatch(a.text.trim());
        subgroups.add(Subgroup(
          id: m.group(1)!,
          label: labelMatch?.group(1) ?? a.text.trim(),
          url: href,
          isActive: (a.attributes['class'] ?? '').contains('active'),
        ));
      }
    }

    // --- days & lessons ----------------------------------------------------
    final days = <ScheduleDay>[];
    if (body != null) {
      String? pendingWeekday;
      _walk(body, (el) {
        if (el.localName == 'div') {
          final classes = el.attributes['class'] ?? '';
          if (classes.contains('d-block') && classes.contains('d-md-none')) {
            final h4 = el.children.length == 1 && el.children.first.localName == 'h4'
                ? el.children.first
                : null;
            if (h4 != null) {
              final text = h4.text.trim();
              for (final wd in _weekdays) {
                if (text.contains(wd)) {
                  pendingWeekday = wd;
                  break;
                }
              }
            }
          }
          return true; // keep recursing into other divs
        }
        if (el.localName == 'table') {
          final classes = el.attributes['class'] ?? '';
          if (classes.contains('m-table')) {
            final weekday = pendingWeekday ?? _weekdayFromTable(el) ?? '?';
            days.add(ScheduleDay(weekday: weekday, lessons: _parseTable(el)));
            pendingWeekday = null;
            return false; // don't recurse into the table we just consumed
          }
        }
        return true;
      });
    }

    return GroupSchedule(
      groupName: groupName,
      weekLabel: weekLabel,
      subgroups: subgroups,
      startDate: startDate,
      endDate: endDate,
      days: days,
      debugRawHtml: htmlBody,
    );
  }

  String? _weekdayFromTable(Element table) {
    final h4 = table.querySelector('h4.kt-font-dark');
    if (h4 == null) return null;
    final text = h4.text.trim();
    for (final wd in _weekdays) {
      if (text.contains(wd)) return wd;
    }
    return null;
  }

  List<Lesson> _parseTable(Element table) {
    final lessons = <Lesson>[];
    for (final row in table.querySelectorAll('tr')) {
      final tds = row.querySelectorAll('td');
      if (tds.length < 3) continue; // malformed/empty row, skip
      final lessonTds = tds.sublist(tds.length - 3);
      final pairTd = lessonTds[0];
      final timeRoomTd = lessonTds[1];
      final contentTd = lessonTds[2];

      final pairMatch = _pairNumber.firstMatch(pairTd.text);
      final pairNumber =
          pairMatch != null ? int.tryParse(pairMatch.group(1)!) : null;

      final timeMatch = _timeRange.firstMatch(timeRoomTd.text);
      final timeRange =
          timeMatch != null ? '${timeMatch.group(1)}–${timeMatch.group(2)}' : null;

      String? room;
      final roomLink = timeRoomTd.querySelector('a.kt-link');
      if (roomLink != null) {
        room = roomLink.text
            .replaceAll('\u00A0', ' ')
            .replaceAll(RegExp(r'^\s*ауд\.?\s*', caseSensitive: false), '')
            .trim();
        if (room.isEmpty) room = null;
      }

      final subject = contentTd.querySelector('span.mr-1')?.text.trim() ?? '';
      final type = contentTd.querySelector('span.badge')?.text.trim();

      final teacherLinks = contentTd
          .querySelectorAll('a.kt-link')
          .map((a) => a.text.trim())
          .where((t) => t.isNotEmpty)
          .toList();

      String? teacherPlainText;
      if (teacherLinks.isEmpty) {
        // Strip the subject/badge line, whatever's left (if any) is a
        // plain-text teacher mention like "доц. Меремсон Ю.Я.".
        var rest = contentTd.text;
        if (subject.isNotEmpty) rest = rest.replaceFirst(subject, '');
        if (type != null) rest = rest.replaceFirst(type, '');
        rest = rest.replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (rest.isNotEmpty) teacherPlainText = rest;
      }

      if (subject.isEmpty && timeRange == null && pairNumber == null) {
        continue; // nothing usable in this row
      }

      lessons.add(Lesson(
        pairNumber: pairNumber,
        timeRange: timeRange,
        room: room,
        subject: subject.isEmpty ? '(без названия)' : subject,
        type: type,
        teachers: teacherLinks,
        teacherPlainText: teacherPlainText,
      ));
    }
    return lessons;
  }

  /// Depth-first walk. [visit] returns false to skip recursing into an
  /// element's children (used once we've fully consumed a <table>).
  void _walk(Element root, bool Function(Element) visit) {
    final shouldRecurse = visit(root);
    if (!shouldRecurse) return;
    for (final child in root.children) {
      _walk(child, visit);
    }
  }
}
