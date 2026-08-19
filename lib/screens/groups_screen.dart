import 'dart:async';

import 'package:flutter/material.dart';

import '../models/group.dart';
import '../services/favorites_service.dart';
import '../services/groups_service.dart';
import 'schedule_screen.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  final _groupsService = GroupsService();
  final _favoritesService = FavoritesService();
  final _searchController = TextEditingController();

  Future<List<Group>>? _future;
  List<Group> _favorites = [];
  String? _primaryGroupId;
  String _query = '';
  String? _formFilter; // null = all
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    _loadFavorites();
    _loadPrimary();
    _maybeOpenLastGroup();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _load({bool forceRefresh = false}) {
    final future = _groupsService.fetchGroups(forceRefresh: forceRefresh);
    setState(() {
      _future = future;
    });
  }

  Future<void> _loadFavorites() async {
    final favs = await _favoritesService.load();
    if (mounted) setState(() => _favorites = favs);
  }

  Future<void> _loadPrimary() async {
    final primary = await _favoritesService.loadPrimaryGroup();
    if (mounted) setState(() => _primaryGroupId = primary?.id);
  }

  /// Pins [group] as the group that opens automatically at launch. Also
  /// makes sure it's in the regular favorites list.
  Future<void> _setPrimary(Group group) async {
    await _favoritesService.savePrimaryGroup(group);
    if (!_favorites.any((g) => g.id == group.id)) {
      await _favoritesService.toggle(group);
    }
    await Future.wait([_loadFavorites(), _loadPrimary()]);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${group.name} теперь открывается сразу при запуске'),
      ));
    }
  }

  Future<void> _clearPrimary() async {
    await _favoritesService.clearPrimaryGroup();
    await _loadPrimary();
  }

  Future<void> _showFavoriteOptions(Group group) async {
    final isPrimary = _primaryGroupId == group.id;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(isPrimary ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(isPrimary
                  ? 'Не открывать автоматически'
                  : 'Открывать сразу при запуске'),
              onTap: () {
                Navigator.pop(sheetContext);
                isPrimary ? _clearPrimary() : _setPrimary(group);
              },
            ),
            ListTile(
              leading: const Icon(Icons.star_border),
              title: const Text('Убрать из избранного'),
              onTap: () {
                Navigator.pop(sheetContext);
                _toggleFavorite(group);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _maybeOpenLastGroup() async {
    // Intentionally not auto-navigating on launch — user lands on the list.
    // Kept as a hook if you want to jump straight to the last group instead.
  }

  Future<void> _openGroup(Group group) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ScheduleScreen(group: group),
    ));
    _loadFavorites();
    _loadPrimary();
  }

  Future<void> _toggleFavorite(Group group) async {
    final favs = await _favoritesService.toggle(group);
    setState(() => _favorites = favs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Расписание ПГУПС'),
      ),
      body: FutureBuilder<List<Group>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorView(message: snapshot.error.toString(), onRetry: _load);
          }

          final all = snapshot.data!;
          if (all.isEmpty) {
            return _ErrorView(
              message: 'Список групп пуст. Попробуйте обновить.',
              onRetry: () => _load(forceRefresh: true),
            );
          }
          final forms = all.map((g) => g.form).toSet().toList();

          final filtered = all.where((g) {
            final matchesQuery = _query.isEmpty ||
                g.name.toLowerCase().contains(_query.toLowerCase());
            final matchesForm = _formFilter == null || g.form == _formFilter;
            return matchesQuery && matchesForm;
          }).toList();

          final byFaculty = <String, List<Group>>{};
          for (final g in filtered) {
            byFaculty.putIfAbsent('${g.course} курс · ${g.faculty}', () => []).add(g);
          }
          final sections = byFaculty.keys.toList()..sort();

          return RefreshIndicator(
            onRefresh: () async {
              // Swipe-down = the one explicit "spend network" action:
              // bypasses the cache and re-fetches through the WebView.
              _load(forceRefresh: true);
              await _future;
            },
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Поиск группы, например АТ-501',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14)),
                        isDense: true,
                      ),
                      onChanged: (v) {
                        _searchDebounce?.cancel();
                        _searchDebounce = Timer(
                          const Duration(milliseconds: 200),
                          () {
                            if (mounted) setState(() => _query = v);
                          },
                        );
                      },
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        _FormChip(
                          label: 'Все формы',
                          selected: _formFilter == null,
                          onTap: () => setState(() => _formFilter = null),
                        ),
                        for (final f in forms)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _FormChip(
                              label: f,
                              selected: _formFilter == f,
                              onTap: () => setState(() => _formFilter = f),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_favorites.isNotEmpty && _query.isEmpty)
                  SliverToBoxAdapter(
                    child: _FavoritesRow(
                      favorites: _favorites,
                      primaryGroupId: _primaryGroupId,
                      onTap: _openGroup,
                      onLongPress: _showFavoriteOptions,
                    ),
                  ),
                for (final section in sections) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(section,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(color: Theme.of(context).colorScheme.primary)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 110,
                        mainAxisExtent: 44,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          final g = byFaculty[section]![i];
                          final isFav = _favorites.any((f) => f.id == g.id);
                          final isPrimary = _primaryGroupId == g.id;
                          return RepaintBoundary(
                            child: _GroupChip(
                              group: g,
                              isFavorite: isFav,
                              isPrimary: isPrimary,
                              onTap: () => _openGroup(g),
                              onLongPress: () => _toggleFavorite(g),
                            ),
                          );
                        },
                        childCount: byFaculty[section]!.length,
                      ),
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FavoritesRow extends StatelessWidget {
  final List<Group> favorites;
  final String? primaryGroupId;
  final void Function(Group) onTap;
  final void Function(Group) onLongPress;
  const _FavoritesRow({
    required this.favorites,
    required this.primaryGroupId,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Избранное', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: favorites.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final g = favorites[i];
              final isPrimary = primaryGroupId == g.id;
              // ActionChip has no long-press hook of its own, so wrap it in
              // a GestureDetector to surface the "pin as primary" menu.
              return GestureDetector(
                onLongPress: () => onLongPress(g),
                child: ActionChip(
                  avatar: Icon(
                    isPrimary ? Icons.push_pin : Icons.star,
                    size: 16,
                    color: Colors.amber,
                  ),
                  label: Text(g.name),
                  onPressed: () => onTap(g),
                  side: isPrimary
                      ? BorderSide(color: Theme.of(context).colorScheme.primary)
                      : null,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FormChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FormChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

class _GroupChip extends StatelessWidget {
  final Group group;
  final bool isFavorite;
  final bool isPrimary;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _GroupChip({
    required this.group,
    required this.isFavorite,
    this.isPrimary = false,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: isFavorite ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          children: [
            Center(
              child: Text(
                group.name,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isPrimary)
              const Positioned(
                top: 2,
                right: 2,
                child: Icon(Icons.push_pin, size: 12, color: Colors.amber),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 40, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Повторить')),
          ],
        ),
      ),
    );
  }
}
