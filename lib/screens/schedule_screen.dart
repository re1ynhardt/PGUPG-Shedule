import 'package:flutter/material.dart';

import '../models/group.dart';
import '../models/lesson.dart';
import '../services/favorites_service.dart';
import '../services/schedule_service.dart';
import '../widgets/lesson_card.dart';
import 'groups_screen.dart';
import 'raw_debug_screen.dart';

class ScheduleScreen extends StatefulWidget {
  final Group group;

  /// True when this screen is the app's launch screen (i.e. [group] is the
  /// pinned "primary" favorite and there's no groups list underneath it in
  /// the navigation stack yet).
  final bool isPrimaryHome;

  const ScheduleScreen({
    super.key,
    required this.group,
    this.isPrimaryHome = false,
  });

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen>
    with TickerProviderStateMixin {
  final _scheduleService = ScheduleService();
  final _favoritesService = FavoritesService();

  Future<GroupSchedule>? _future;
  bool _isFavorite = false;
  bool _isPrimary = false;
  TabController? _tabController;

  String? _selectedSubgroupId;
  DateTime? _weekAnchor; // Monday-ish reference date for the displayed week

  static const _weekdayShort = {
    'Понедельник': 'Пн',
    'Вторник': 'Вт',
    'Среда': 'Ср',
    'Четверг': 'Чт',
    'Пятница': 'Пт',
    'Суббота': 'Сб',
    'Воскресенье': 'Вс',
  };

  @override
  void initState() {
    super.initState();
    _load();
    _checkFavorite();
    _checkPrimary();
    _favoritesService.saveLastGroup(widget.group);
  }

  void _load({bool resetTab = true, bool forceRefresh = false}) {
    final url = ScheduleService.buildUrl(
      groupId: widget.group.id,
      subgroupId: _selectedSubgroupId,
      weekStart: _weekAnchor,
    );
    final future = _scheduleService.fetchSchedule(
      url,
      widget.group.name,
      forceRefresh: forceRefresh,
    );
    setState(() {
      _future = future;
      if (resetTab) {
        _tabController?.dispose();
        _tabController = null;
      }
    });
    future.then((schedule) {
      if (!mounted) return;
      setState(() {
        _weekAnchor ??= schedule.startDate;
        if (_selectedSubgroupId == null && schedule.subgroups.isNotEmpty) {
          final active = schedule.subgroups.where((s) => s.isActive);
          _selectedSubgroupId =
              active.isNotEmpty ? active.first.id : schedule.subgroups.first.id;
        }
      });
    }).catchError((_) {});
  }

  Future<void> _checkFavorite() async {
    final favs = await _favoritesService.load();
    if (mounted) setState(() => _isFavorite = favs.any((g) => g.id == widget.group.id));
  }

  Future<void> _toggleFavorite() async {
    final favs = await _favoritesService.toggle(widget.group);
    if (mounted) setState(() => _isFavorite = favs.any((g) => g.id == widget.group.id));
  }

  Future<void> _checkPrimary() async {
    final isPrimary = await _favoritesService.isPrimaryGroup(widget.group);
    if (mounted) setState(() => _isPrimary = isPrimary);
  }

  Future<void> _togglePrimary() async {
    if (_isPrimary) {
      await _favoritesService.clearPrimaryGroup();
      if (mounted) {
        setState(() => _isPrimary = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Группа больше не открывается автоматически'),
        ));
      }
    } else {
      // Only one group can be primary at a time.
      await _favoritesService.savePrimaryGroup(widget.group);
      // Being the primary group implies being a regular favorite too, so
      // it also shows up in the favorites row on the groups screen.
      if (!_isFavorite) {
        final favs = await _favoritesService.toggle(widget.group);
        if (mounted) setState(() => _isFavorite = favs.any((g) => g.id == widget.group.id));
      }
      if (mounted) {
        setState(() => _isPrimary = true);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Теперь эта группа открывается сразу при запуске'),
        ));
      }
    }
  }

  void _shiftWeek(int days) {
    final base = _weekAnchor ?? DateTime.now();
    setState(() => _weekAnchor = base.add(Duration(days: days)));
    _load();
  }

  void _selectSubgroup(String id) {
    setState(() => _selectedSubgroupId = id);
    _load();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        leading: widget.isPrimaryHome
            ? IconButton(
                icon: const Icon(Icons.menu),
                tooltip: 'Все группы',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const GroupsScreen(),
                )),
              )
            : null,
        actions: [
          IconButton(
            icon: Icon(_isPrimary ? Icons.push_pin : Icons.push_pin_outlined),
            color: _isPrimary ? Colors.amber : null,
            tooltip: _isPrimary
                ? 'Не открывать автоматически'
                : 'Открывать сразу при запуске',
            onPressed: _togglePrimary,
          ),
          IconButton(
            icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
            color: _isFavorite ? Colors.amber : null,
            tooltip: _isFavorite ? 'Убрать из избранного' : 'В избранное',
            onPressed: _toggleFavorite,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: () => _load(resetTab: false, forceRefresh: true),
          ),
        ],
      ),
      body: FutureBuilder<GroupSchedule>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorView(error: snapshot.error, onRetry: () => _load());
          }

          final schedule = snapshot.data!;
          _tabController ??=
              TabController(length: schedule.days.length.clamp(1, 100), vsync: this);

          return RefreshIndicator(
            // The one explicit "spend network" action: swiping down
            // bypasses the cache and re-fetches through the WebView.
            onRefresh: () async {
              _load(resetTab: false, forceRefresh: true);
              await _future;
            },
            child: Column(
              children: [
                _TopBar(
                  schedule: schedule,
                  onPrevWeek: () => _shiftWeek(-7),
                  onNextWeek: () => _shiftWeek(7),
                ),
                if (schedule.subgroups.length > 1)
                  _SubgroupBar(
                    subgroups: schedule.subgroups,
                    selectedId: _selectedSubgroupId,
                    onSelect: _selectSubgroup,
                  ),
                if (schedule.days.length > 1)
                  TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabs: schedule.days
                        .map((d) => Tab(text: _weekdayShort[d.weekday] ?? d.weekday))
                        .toList(),
                  ),
                Expanded(
                  child: schedule.days.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: Text('Расписание не найдено')),
                            ),
                          ],
                        )
                      : schedule.days.length > 1
                          ? TabBarView(
                              controller: _tabController,
                              children:
                                  schedule.days.map((d) => _DayList(day: d)).toList(),
                            )
                          : _DayList(day: schedule.days.first),
                ),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FutureBuilder<GroupSchedule>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const SizedBox.shrink();
          return FloatingActionButton.small(
            heroTag: 'debug_${widget.group.id}',
            tooltip: 'Показать сырой HTML (для отладки парсера)',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RawDebugScreen(rawText: snapshot.data!.debugRawHtml),
            )),
            child: const Icon(Icons.bug_report_outlined),
          );
        },
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final GroupSchedule schedule;
  final VoidCallback onPrevWeek;
  final VoidCallback onNextWeek;
  const _TopBar({required this.schedule, required this.onPrevWeek, required this.onNextWeek});

  String _fmtDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final range = schedule.startDate != null && schedule.endDate != null
        ? '${_fmtDate(schedule.startDate!)}–${_fmtDate(schedule.endDate!)}'
        : null;
    return Container(
      width: double.infinity,
      color: theme.colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            color: theme.colorScheme.onPrimaryContainer,
            onPressed: onPrevWeek,
            tooltip: 'Предыдущая неделя',
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (schedule.weekLabel != null)
                  Text(
                    schedule.weekLabel!,
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                if (range != null)
                  Text(
                    range,
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer.withOpacity(0.8),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            color: theme.colorScheme.onPrimaryContainer,
            onPressed: onNextWeek,
            tooltip: 'Следующая неделя',
          ),
        ],
      ),
    );
  }
}

class _SubgroupBar extends StatelessWidget {
  final List<Subgroup> subgroups;
  final String? selectedId;
  final void Function(String) onSelect;
  const _SubgroupBar({required this.subgroups, required this.selectedId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Text('Подгруппа:', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          ...subgroups.map((s) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(s.label),
                  selected: selectedId == s.id,
                  onSelected: (_) => onSelect(s.id),
                ),
              )),
        ],
      ),
    );
  }
}

class _DayList extends StatelessWidget {
  final ScheduleDay day;
  const _DayList({required this.day});

  @override
  Widget build(BuildContext context) {
    if (day.lessons.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Пар нет', textAlign: TextAlign.center)),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: day.lessons.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => RepaintBoundary(child: LessonCard(lesson: day.lessons[i])),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final httpError = error is ScheduleHttpException ? error as ScheduleHttpException : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(error.toString(), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Повторить')),
            if (httpError != null) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RawDebugScreen(
                    rawText: 'HTTP ${httpError.statusCode}\n\n'
                        'Заголовки ответа:\n'
                        '${httpError.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n')}'
                        '\n\n--- Тело ответа ---\n\n'
                        '${httpError.responseBody}',
                  ),
                )),
                child: const Text('Показать ответ сервера'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
