import 'package:flutter/material.dart';

import '../models/lesson.dart';

class LessonCard extends StatelessWidget {
  final Lesson lesson;
  const LessonCard({super.key, required this.lesson});

  Color _typeColor(BuildContext context, String? type) {
    final scheme = Theme.of(context).colorScheme;
    if (type == null) return scheme.outline;
    final t = type.toLowerCase();
    if (t.contains('лекция')) return scheme.primary;
    if (t.contains('практ')) return Colors.teal;
    if (t.contains('лаб')) return Colors.deepOrange;
    if (t.contains('семинар')) return Colors.purple;
    if (t.contains('экзамен') || t.contains('зач')) return Colors.red;
    return scheme.outline;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typeColor = _typeColor(context, lesson.type);
    final teacher = lesson.teacherDisplay;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (lesson.pairNumber != null)
                    Text('${lesson.pairNumber} пара',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  Text(
                    lesson.timeRange ?? '—',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            Container(width: 3, height: 40, color: typeColor, margin: const EdgeInsets.only(right: 12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(lesson.subject,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (lesson.type != null)
                        _Tag(icon: Icons.school_outlined, text: lesson.type!, color: typeColor),
                      if (lesson.room != null)
                        _Tag(icon: Icons.location_on_outlined, text: 'ауд. ${lesson.room}'),
                    ],
                  ),
                  if (teacher != null) ...[
                    const SizedBox(height: 4),
                    _WrappingTag(icon: Icons.person_outline, text: teacher),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Like [_Tag] but takes the full available width so long text (e.g. a
/// list of several teacher names) wraps onto additional lines instead of
/// overflowing the card horizontally.
class _WrappingTag extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const _WrappingTag({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.outline;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: c),
        ),
        const SizedBox(width: 3),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: c)),
        ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const _Tag({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 12, color: c)),
      ],
    );
  }
}
