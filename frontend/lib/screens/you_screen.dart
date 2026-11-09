import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/format.dart';
import '../widgets/money_in.dart';
import '../widgets/panel.dart';
import 'about_numbers_screen.dart';
import 'privacy_screen.dart';
import 'payees_screen.dart';
import 'profile_screen.dart';
import 'spending_screen.dart';

/// You: household and income, privacy, appearance, log out, delete account.
class YouScreen extends StatelessWidget {
  const YouScreen({super.key});

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
      padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        Center(
          child: CircleAvatar(
            radius: 44,
            backgroundColor: c.lime,
            child: (p?.name ?? '').isNotEmpty
                ? Text(p!.name!.characters.first.toUpperCase(),
                    style: theme.textTheme.headlineLarge?.copyWith(color: c.onLime, fontWeight: FontWeight.w700))
                : Icon(Icons.person_rounded, size: 44, color: c.onLime),
          ),
        ),
        const SizedBox(height: 12),
        if ((p?.name ?? '').isNotEmpty)
          Text(p!.name!, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
        if (p?.email != null)
          Text(p!.email!, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
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
        if (p != null)
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text('Money coming in', style: theme.textTheme.titleMedium)),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(backgroundColor: c.field, foregroundColor: theme.colorScheme.onSurface),
                  onPressed: () => push(const ProfileScreen()),
                  child: const Text('Edit'),
                ),
              ]),
              const SizedBox(height: 8),
              if (p.incomes.isEmpty)
                Text('No income added yet.', style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
              for (final i in p.incomes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(child: Text(i.name, style: theme.textTheme.bodyLarge)),
                    Text('KES ${money(i.monthly)} a month', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  ]),
                ),
              if (p.incomes.length > 1) ...[
                const Divider(height: 20),
                Row(children: [
                  Expanded(child: Text('Total', style: theme.textTheme.bodyLarge)),
                  Text('KES ${money(p.monthlyIncome)}', style: theme.textTheme.titleMedium),
                ]),
              ],
              if (p.incomeLow != null) ...[
                const SizedBox(height: 6),
                Text('A low month: about KES ${money(p.incomeLow!)}', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
              ],
            ]),
          ),
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
              leading: const Icon(Icons.account_balance_rounded),
              title: const Text('Money outside M-PESA'),
              subtitle: const Text('An allowance paid to a bank, cash, card spending'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                final p = await state.api.getProfile();
                if (context.mounted) {
                  await editOutsideMoney(context,
                      income: p?['outsideIncome'] as num?, spending: p?['outsideSpending'] as num?);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_rounded),
              title: const Text('Your records'),
              subtitle: const Text('Search, change or delete any payment'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => push(const SpendingScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.people_rounded),
              title: const Text('Who you pay and who pays you'),
              subtitle: const Text('What each person and business is'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => push(const PayeesScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('About these numbers'),
              subtitle: const Text('Which models, what data, and their limits'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => push(const AboutNumbersScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.lock_rounded),
              title: const Text('Privacy and consent'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showPrivacy(context, state.api),
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
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
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
