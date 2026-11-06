import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

class _Dest {
  const _Dest(this.label, this.title, this.icon);
  final String label;   // read out by screen readers and shown as a tooltip
  final String title;   // the page heading
  final IconData icon;
}

const _dests = [
  _Dest('Overview', 'Overview', Icons.home_rounded),
  _Dest('Can I afford it?', 'Can I afford it?', Icons.verified_user_rounded),
  _Dest('Forecast and budget', 'Forecast and budget', Icons.bar_chart_rounded),
  _Dest('Plans: bills, debts and goals', 'Plans', Icons.calendar_month_rounded),
  _Dest('You', 'You', Icons.person_rounded),
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

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _admin = false;
  final _opened = <int>{0};   // tabs load the first time they are opened, not all five at start-up

  @override
  void initState() {
    super.initState();
    context.read<AppState>().api.isAdmin().then((a) {
      if (mounted) setState(() => _admin = a);
    }).catchError((_) {});
  }

  void _go(int i) => setState(() {
        _tab = i;
        _opened.add(i);
      });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>(); // rebuild when the household changes
    final pages = [
      DashboardScreen(onAddSpending: () => showAddSheet(context), onOpenTab: _go),
      const AffordScreen(),
      const ForecastScreen(),
      const CommitmentsScreen(),
      YouScreen(admin: _admin),
    ];
    final body = IndexedStack(index: _tab, children: [
      for (var i = 0; i < pages.length; i++) _opened.contains(i) ? pages[i] : const SizedBox.shrink(),
    ]);

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= HomeScreen.wideFrom;
      final page = _Page(
        title: _dests[_tab].title,
        greeting: _tab == 0 ? 'Habari${(state.profile?.name ?? '').isNotEmpty ? ', ${state.profile!.name}' : ''}' : null,
        onAdd: _tab == 0 ? () => showAddSheet(context) : null,
        onRecords: _tab == 0 || _tab == 2
            ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SpendingScreen()))
            : null,
        wide: wide,
        child: body,
      );
      if (wide) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _Rail(selected: _tab, onSelect: _go),
                const SizedBox(width: 16),
                Expanded(child: page),
              ]),
            ),
          ),
        );
      }
      return Scaffold(
        body: Stack(children: [
          SafeArea(bottom: false, child: Padding(padding: const EdgeInsets.only(bottom: 92), child: page)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 22 + MediaQuery.paddingOf(context).bottom,
            child: Center(child: _PillNav(selected: _tab, onSelect: _go)),
          ),
        ]),
      );
    });
  }
}

/// The page heading, then the page. Overview also gets the greeting and the Add button.
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.child, required this.wide, this.greeting, this.onAdd, this.onRecords});
  final String title;
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
                  ? FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded), label: const Text('Add records'))
                  : IconButton.filled(tooltip: 'Add records', onPressed: onAdd, icon: const Icon(Icons.add_rounded)),
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
  final _Dest dest;
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

class _Rail extends StatelessWidget {
  const _Rail({required this.selected, required this.onSelect});
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget item(int i) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _NavButton(dest: _dests[i], selected: i == selected, onTap: () => onSelect(i), size: 48, idle: c.navIcon),
        );
    return Container(
      width: 76,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(color: c.nav, borderRadius: BorderRadius.circular(28)),
      child: Column(children: [
        const ToshaLogo(size: 40),
        const SizedBox(height: 28),
        for (var i = 0; i < 4; i++) item(i),
        const Spacer(),
        item(4),
      ]),
    );
  }
}

class _PillNav extends StatelessWidget {
  const _PillNav({required this.selected, required this.onSelect});
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
        for (var i = 0; i < _dests.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          _NavButton(dest: _dests[i], selected: i == selected, onTap: () => onSelect(i), size: 52, idle: Colors.white),
        ],
      ]),
    );
  }
}
