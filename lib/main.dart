import 'package:flutter/material.dart';

import 'screens/app_home_screen.dart';
import 'theme.dart';
import 'widgets/pgups_webview_host.dart';

void main() {
  runApp(const PgupsScheduleApp());
}

class PgupsScheduleApp extends StatelessWidget {
  const PgupsScheduleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Расписание ПГУПС',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      // Mounted once here (rather than per-screen) so the same WebView /
      // cookie jar that PgupsWebFetcher drives survives navigation between
      // screens instead of being torn down and recreated on every request.
      builder: (context, child) =>
          PgupsWebViewHost(child: child ?? const SizedBox.shrink()),
      home: const AppHomeScreen(),
    );
  }
}
