import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/choice_sheet.dart';
import 'admin_screen.dart';
import 'privacy_screen.dart';
import 'profile_screen.dart';

/// You: household and income, privacy, appearance, log out, delete account.
class YouScreen extends StatelessWidget {
  const YouScreen({super.key, this.admin = false});
  final bool admin;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final themes = context.watch<ThemeController>();
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final p = state.profile;

    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

    Future<void> logOut() async {
      final everywhere = await showChoiceSheet<bool>(
        context,
        title: 'Log out?',
        message: "Your records stay safe. You'll need your email and password to come back.",
        choices: const [SheetChoice('Log out', false, primary: true), SheetChoice('Log out on all devices', true)],
      );
      if (everywhere != null && context.mounted) await context.read<AppState>().logOut(everywhere: everywhere);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Center(
          child: CircleAvatar(
            radius: 44,
            backgroundColor: c.lime,
            child: Icon(Icons.person_rounded, size: 44, color: c.onLime),
          ),
        ),
        const SizedBox(height: 16),
        if (p != null)
          Row(children: [
            _Stat(value: '${p.householdSize}', label: p.householdSize == 1 ? 'Person' : 'People'),
            const SizedBox(width: 10),
            _Stat(value: _short(p.monthlyIncome), label: 'A month'),
            const SizedBox(width: 10),
            _Stat(value: _short(p.savingsBalance), label: 'Saved'),
          ]),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.home_rounded),
              title: const Text('Household and income'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => push(const ProfileScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.lock_rounded),
              title: const Text('Privacy and consent'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showPrivacy(context, state.api),
            ),
            if (admin)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_rounded),
                title: const Text('Admin'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => push(const AdminScreen()),
              ),
          ]),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Appearance', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ButtonSegment(value: ThemeMode.system, label: Text('Phone')),
                ],
                selected: {themes.mode},
                onSelectionChanged: (s) => context.read<ThemeController>().set(s.first),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: logOut, child: const Text('Log out')),
        const SizedBox(height: 4),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: c.warn),
          onPressed: () => confirmDeleteAccount(context),
          child: const Text('Delete my account'),
        ),
      ],
    );
  }

  static String _short(double kes) =>
      kes >= 1000 ? '${(kes / 1000).toStringAsFixed(kes >= 10000 ? 0 : 1)}k' : kes.toStringAsFixed(0);
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(color: theme.colorScheme.surface, borderRadius: BorderRadius.circular(22)),
        child: Column(children: [
          Text(value, style: theme.textTheme.titleLarge),
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).muted)),
        ]),
      ),
    );
  }
}
