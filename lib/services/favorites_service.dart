import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/group.dart';

class FavoritesService {
  static const _key = 'favorite_groups_v1';
  static const _lastGroupKey = 'last_selected_group_v1';
  static const _primaryGroupKey = 'primary_group_v1';

  Future<List<Group>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(Group.fromJson).toList();
  }

  Future<void> save(List<Group> groups) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(groups.map((g) => g.toJson()).toList()));
  }

  Future<List<Group>> toggle(Group group) async {
    final current = await load();
    final exists = current.any((g) => g.id == group.id);
    if (exists) {
      current.removeWhere((g) => g.id == group.id);
    } else {
      current.add(group);
    }
    await save(current);
    return current;
  }

  Future<void> saveLastGroup(Group group) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastGroupKey, jsonEncode(group.toJson()));
  }

  Future<Group?> loadLastGroup() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastGroupKey);
    if (raw == null) return null;
    return Group.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// The "primary" favorite group: the one group that should always be
  /// reachable instantly. When set, the app opens straight into its
  /// schedule on launch instead of showing the groups list.
  Future<void> savePrimaryGroup(Group group) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_primaryGroupKey, jsonEncode(group.toJson()));
  }

  Future<Group?> loadPrimaryGroup() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_primaryGroupKey);
    if (raw == null) return null;
    return Group.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> clearPrimaryGroup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_primaryGroupKey);
  }

  Future<bool> isPrimaryGroup(Group group) async {
    final primary = await loadPrimaryGroup();
    return primary?.id == group.id;
  }
}
