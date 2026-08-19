import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RawDebugScreen extends StatelessWidget {
  final String rawText;
  const RawDebugScreen({super.key, required this.rawText});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Отладка: сырой текст страницы'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Скопировать',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: rawText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Скопировано в буфер обмена')),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Это построчный текст, извлечённый из HTML страницы группы. '
              'Если расписание распознаётся неверно — посмотрите здесь, как '
              'реально выглядят строки (время, дни недели, преподаватели), '
              'и подправьте регулярные выражения в lib/services/schedule_service.dart.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  rawText.isEmpty ? '(пусто)' : rawText,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
