import 'package:flutter/material.dart';

import '../models/group.dart';
import '../services/favorites_service.dart';
import 'groups_screen.dart';
import 'schedule_screen.dart';

/// Decides what the user sees right after launch.
///
/// If a "primary" favorite group has been pinned (via the pin icon on
/// [ScheduleScreen] or the favorites row on [GroupsScreen]), that group's
/// schedule opens immediately — no need to search/tap through the group
/// list every time. Otherwise the app falls back to the groups list as
/// before.
class AppHomeScreen extends StatefulWidget {
  const AppHomeScreen({super.key});

  @override
  State<AppHomeScreen> createState() => _AppHomeScreenState();
}

class _AppHomeScreenState extends State<AppHomeScreen> {
  final _favoritesService = FavoritesService();
  late final Future<Group?> _primaryFuture =
      _favoritesService.loadPrimaryGroup();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Group?>(
      future: _primaryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final primary = snapshot.data;
        if (primary != null) {
          return ScheduleScreen(group: primary, isPrimaryHome: true);
        }
        return const GroupsScreen();
      },
    );
  }
}
