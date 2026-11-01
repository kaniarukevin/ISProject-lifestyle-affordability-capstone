import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'commitments_screen.dart';
import 'profile_screen.dart';

/// The app's main frame. Each tab is one step of the user journey; most are placeholders for now.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<AppState>().profile!;
    final pages = [
      _Placeholder(
        title: 'Dashboard',
        text: 'Coming next: your financial state, next month\'s forecast and where your money goes.\n\n'
            'Monthly income so far: ${kes(profile.monthlyIncome)}',
      ),
      const _Placeholder(title: 'Budget', text: 'Coming: your monthly limits per category.'),
      const _Placeholder(title: 'Can I afford it?', text: 'Coming: test a lifestyle change before you commit.'),
      const CommitmentsScreen(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lifestyle Affordability'),
        actions: [
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
          NavigationDestination(icon: Icon(Icons.event_note_outlined), label: 'Commitments'),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title, required this.text});

  final String title, text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(text),
          ],
        ),
      );
}
