import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'spending_screen.dart';
import 'statement_screen.dart';

/// "Add records": the three ways records come in, one tap from Overview. A sheet on every screen size.
Future<void> showAddSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        final c = AppColors.of(sheet);
        void open(Widget page) {
          Navigator.pop(sheet);
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Add records', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text('More records make the forecast and your score closer to real life.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                const SizedBox(height: 16),
                _Option(
                  dark: true,
                  icon: Icons.upload_file_rounded,
                  title: 'Upload an M-PESA statement',
                  subtitle: 'Totals checked, file never kept',
                  onTap: () => open(const StatementScreen()),
                ),
                const SizedBox(height: 10),
                _Option(
                  icon: Icons.sms_rounded,
                  title: 'Paste M-PESA messages',
                  subtitle: 'Keeps you current between statements',
                  onTap: () => open(const StatementScreen(messages: true)),
                ),
                const SizedBox(height: 10),
                _Option(
                  icon: Icons.edit_rounded,
                  title: 'Type it in',
                  subtitle: 'Cash and anything else',
                  onTap: () => open(const SpendingScreen()),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: () => open(const SpendingScreen()), child: const Text('See all records')),
                ),
              ],
            ),
          ),
        );
      },
    );

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.title, required this.subtitle, required this.onTap, this.dark = false});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final bg = dark ? const Color(0xFF111111) : theme.colorScheme.surface;
    final fg = dark ? Colors.white : theme.colorScheme.onSurface;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: dark ? c.lime : c.field,
              child: Icon(icon, color: dark ? c.onLime : fg),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleMedium?.copyWith(color: fg)),
                Text(subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(color: dark ? const Color(0xFFD4D4CE) : c.muted)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
