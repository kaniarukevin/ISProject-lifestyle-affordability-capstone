import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/tosha_logo.dart';
import 'add_sheet.dart';
import 'afford_screen.dart';
import 'commitments_screen.dart';
import 'dashboard_screen.dart';
import 'forecast_screen.dart';
import 'spending_screen.dart';
import 'you_screen.dart';

class NavDest {
  const NavDest(this.label, this.title, this.icon);
  final String label;   // read out by screen readers and shown as a tooltip
  final String title;   // the page heading
  final IconData icon;
}

const _dests = [
  // 10 Nov: names people would look for (testers could not find the budget or where bills and goals live).
  NavDest('Home: how you are doing', 'How you\'re doing', Icons.home_rounded),
  NavDest('Can I afford it?', 'Can I afford it?', Icons.verified_user_rounded),
  NavDest('Budget and the next 3 months', 'Budget and next 3 months', Icons.bar_chart_rounded),
  NavDest('Bills, debts and goals', 'Bills, debts and goals', Icons.calendar_month_rounded),
  NavDest('You', 'You', Icons.person_rounded),
];

/// Tosha's frame: five places, the same on every screen size. Under 600 px wide a floating black pill bar at the
/// bottom; wider, the black rounded rail on the left (design canvas, 6 Nov). Each tab keeps its place when you
/// switch away and back.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static const wideFrom = 600.0;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  DateTime? _away;

  // Where you were, so a reload opens the same place (cache_v1_ keys are wiped at log out, like the figures).
  static const _placeKey = 'cache_v1_place';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restorePlace();
    _requests = context.read<AppState>().tabRequest..addListener(_onTabRequest);
  }

  ValueNotifier<int?>? _requests;

  void _onTabRequest() {
    final t = _requests?.value;
    if (t != null && mounted) _go(t.clamp(0, _dests.length - 1));
  }

  Future<void> _restorePlace() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_placeKey);
    if (saved == null || !mounted) return;
    final parts = saved.split('|');
    final tab = int.tryParse(parts.first) ?? 0;
    setState(() {
      _tab = tab.clamp(0, _dests.length - 1);
      _opened.add(_tab);
      _records = parts.length > 1 && parts[1] != '-' ? parts[1] : null;
    });
  }

  Future<void> _savePlace() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_placeKey, '$_tab|${_records ?? '-'}');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _requests?.removeListener(_onTabRequest);
    super.dispose();
  }

  /// Back in the app after more than a minute away (another tab, another app, the phone locked): the screens
  /// refresh quietly, since figures may have changed elsewhere, for example on another device.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) _away ??= DateTime.now();
    if (s == AppLifecycleState.resumed) {
      final away = _away;
      _away = null;
      if (away != null && DateTime.now().difference(away) > const Duration(minutes: 1) && mounted) {
        context.read<AppState>().dataChanged();
      }
    }
  }
  final _opened = <int>{0};   // tabs load the first time they are opened, not all five at start-up

  /// Records open inside the tab you are on (the nav stays); null when closed, '' for the newest month.
  String? _records;

  void _go(int i) {
    setState(() {
      _tab = i;
      _opened.add(i);
      _records = null;
    });
    _savePlace();
  }

  void _openRecords([String month = '']) {
    setState(() => _records = month);
    _savePlace();
  }

  void _closeRecords() {
    setState(() => _records = null);
    _savePlace();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>(); // rebuild when the household changes
    final pages = [
      DashboardScreen(onAddSpending: () => showAddSheet(context), onOpenTab: _go, onOpenRecords: _openRecords),
      const AffordScreen(),
      const ForecastScreen(),
      const CommitmentsScreen(),
      const YouScreen(),
    ];
    final tabs = IndexedStack(index: _tab, children: [
      for (var i = 0; i < pages.length; i++) _opened.contains(i) ? pages[i] : const SizedBox.shrink(),
    ]);
    final body = _records == null
        ? tabs
        : RecordsView(key: ValueKey('records-$_records'), month: _records!.isEmpty ? null : _records);

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= HomeScreen.wideFrom;
      final inRecords = _records != null;
      final page = _Page(
        title: inRecords ? 'Your records' : _dests[_tab].title,
        greeting: _tab == 0 && !inRecords
            ? 'Habari${(state.profile?.name ?? '').isNotEmpty ? ', ${state.profile!.name}' : ''}'
            : null,
        onBack: inRecords ? _closeRecords : null,
        onAdd: _tab == 0 || inRecords ? () => showAddSheet(context) : null,
        onRecords: (_tab == 0 || _tab == 2) && !inRecords ? _openRecords : null,
        wide: wide,
        child: body,
      );
      if (wide) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                NavRail(dests: _dests, selected: _tab, onSelect: _go),
                const SizedBox(width: 16),
                Expanded(child: page),
              ]),
            ),
          ),
        );
      }
      return Scaffold(
        body: Stack(children: [
          // Pages run to the bottom of the screen and scroll behind the pill (9 Nov: the empty band above it wasted
            // space). The extra bottom padding tells each page's list to leave room so its last card clears the pill.
            SafeArea(bottom: false, child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  padding: MediaQuery.paddingOf(context).copyWith(bottom: MediaQuery.paddingOf(context).bottom + 92)),
              child: page,
            )),
          Positioned(
            left: 0,
            right: 0,
            bottom: 22 + MediaQuery.paddingOf(context).bottom,
            child: Center(child: PillNav(dests: _dests, selected: _tab, onSelect: _go)),
          ),
        ]),
      );
    });
  }
}

/// The page heading, then the page. Overview also gets the greeting and the Add button.
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.child, required this.wide, this.greeting, this.onAdd, this.onRecords,
      this.onBack});
  final String title;
  final VoidCallback? onBack;
  final String? greeting;
  final VoidCallback? onAdd;
  final VoidCallback? onRecords;
  final bool wide;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: wide ? 16 : 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.only(top: wide ? 18 : 16, bottom: 12),
          child: Row(children: [
            if (onBack != null) ...[
              IconButton.filledTonal(tooltip: 'Back', onPressed: onBack, icon: const Icon(Icons.arrow_back_rounded)),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (greeting != null) Text(greeting!, style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                Text(title, style: wide ? theme.textTheme.headlineMedium : theme.textTheme.headlineSmall),
              ]),
            ),
            if (onRecords != null) ...[
              wide
                  ? FilledButton.tonal(onPressed: onRecords, child: const Text('Records'))
                  : IconButton.filledTonal(tooltip: 'Your records', onPressed: onRecords, icon: const Icon(Icons.receipt_long_rounded)),
              const SizedBox(width: 8),
            ],
            if (onAdd != null)
              wide
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: c.lime, foregroundColor: c.onLime),
                      onPressed: onAdd, icon: const Icon(Icons.add_rounded), label: const Text('Add records'))
                  : IconButton.filled(
                      style: IconButton.styleFrom(backgroundColor: c.lime, foregroundColor: c.onLime),
                      tooltip: 'Add records', onPressed: onAdd, icon: const Icon(Icons.add_rounded)),
          ]),
        ),
        Expanded(child: child),
      ]),
    );
  }
}

/// One round navigation button: lime when it is the current page.
class _NavButton extends StatelessWidget {
  const _NavButton({required this.dest, required this.selected, required this.onTap, required this.size, required this.idle});
  final NavDest dest;
  final bool selected;
  final VoidCallback onTap;
  final double size;
  final Color idle;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tooltip(
      message: dest.label,
      child: Semantics(
        button: true,
        selected: selected,
        label: dest.label,
        excludeSemantics: true,
        child: Material(
          color: selected ? c.lime : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: size,
              child: Icon(dest.icon, size: 22, color: selected ? c.onLime : idle),
            ),
          ),
        ),
      ),
    );
  }
}

class NavRail extends StatelessWidget {
  const NavRail({super.key, required this.dests, required this.selected, required this.onSelect});
  final List<NavDest> dests;   // the last one sits at the bottom of the rail
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget item(int i) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _NavButton(dest: dests[i], selected: i == selected, onTap: () => onSelect(i), size: 48, idle: c.navIcon),
        );
    return Container(
      width: 76,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(color: c.nav, borderRadius: BorderRadius.circular(28)),
      child: Column(children: [
        const ToshaLogo(size: 40),
        const SizedBox(height: 28),
        for (var i = 0; i < dests.length - 1; i++) item(i),
        const Spacer(),
        item(dests.length - 1),
      ]),
    );
  }
}

class PillNav extends StatelessWidget {
  const PillNav({super.key, required this.dests, required this.selected, required this.onSelect});
  final List<NavDest> dests;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: c.nav,
        borderRadius: BorderRadius.circular(32),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < dests.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          _NavButton(dest: dests[i], selected: i == selected, onTap: () => onSelect(i), size: 52, idle: Colors.white),
        ],
      ]),
    );
  }
}
