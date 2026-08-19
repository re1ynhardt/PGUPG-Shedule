class Lesson {
  final int? pairNumber; // 1..N, parsed from "N пара"
  final String? timeRange; // "10:45–12:15"
  final String? room; // "2-402", "Хим. Лаб.", "6-201,6-206" — prefix "ауд." stripped
  final String subject;
  final String? type; // "Лекция" / "Практические занятия" / "Лабораторные занятия" / ...
  final List<String> teachers; // parsed from <a class="kt-link" href=".../teacher/..">
  final String? teacherPlainText; // fallback when the teacher isn't a link (e.g. "доц. Меремсон Ю.Я.")

  const Lesson({
    this.pairNumber,
    this.timeRange,
    this.room,
    required this.subject,
    this.type,
    this.teachers = const [],
    this.teacherPlainText,
  });

  /// Convenience for display: joined teacher names, whichever source they came from.
  String? get teacherDisplay {
    if (teachers.isNotEmpty) return teachers.join(', ');
    if (teacherPlainText != null && teacherPlainText!.trim().isNotEmpty) {
      return teacherPlainText!.trim();
    }
    return null;
  }
}

class ScheduleDay {
  final String weekday; // "Понедельник" etc
  final List<Lesson> lessons;

  const ScheduleDay({required this.weekday, required this.lessons});
}

class Subgroup {
  final String id;
  final String label; // usually just a number: "1", "2"
  final String url;
  final bool isActive;

  const Subgroup({
    required this.id,
    required this.label,
    required this.url,
    required this.isActive,
  });
}

class GroupSchedule {
  final String groupName;
  final String? weekLabel; // "Четная неделя" / "Нечетная неделя", parsed straight from the site banner
  final List<Subgroup> subgroups;
  final DateTime? startDate; // start of the displayed week, if the page exposed it
  final DateTime? endDate;
  final List<ScheduleDay> days;
  final String debugRawHtml; // raw HTML, for the debug screen

  const GroupSchedule({
    required this.groupName,
    required this.weekLabel,
    required this.subgroups,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.debugRawHtml,
  });
}

