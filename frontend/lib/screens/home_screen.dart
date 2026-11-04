import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'admin_screen.dart';
import 'afford_screen.dart';
import 'budget_screen.dart';
import 'commitments_screen.dart';
import 'dashboard_screen.dart';
import 'spending_screen.dart';
import 'profile_screen.dart';

/// The app's main frame. Each tab is one step of the user journey; most are placeholders for now.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _admin = false;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().api.isAdmin().then((a) {
      if (mounted) setState(() => _admin = a);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>(); // rebuild when the household changes
    final pages = [
      DashboardScreen(onAddSpending: () => setState(() => _tab = 3)),
      const BudgetScreen(),
      const AffordScreen(),
      const SpendingScreen(),
      const CommitmentsScreen(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lifestyle Affordability'),
        actions: [
          if (_admin)
            IconButton(
              tooltip: 'Admin',
              icon: const Icon(Icons.admin_panel_settings_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminScreen())),
            ),
          IconButton(
            tooltip: 'Edit household',
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: () => context.read<AppState>().signOut(),
          ),
        ],
      ),
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: 'Budget'),
          NavigationDestination(icon: Icon(Icons.help_outline), label: 'Afford?'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Spending'),
          NavigationDestination(icon: Icon(Icons.event_note_outlined), label: 'Commitments'),
        ],
      ),
    );
  }
}
