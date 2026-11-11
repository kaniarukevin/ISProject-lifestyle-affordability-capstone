import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One line of a list of notes ("Good to know", "What changed this month"): a circled icon saying what kind of
/// note it is, then the words. Plain bullets read as fine print and testers skipped them (11 Nov).
class NoteRow extends StatelessWidget {
  const NoteRow(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final s = text.toLowerCase();
    final warn = s.contains('more than comes in') ||
        s.contains('more than your income') ||
        s.contains('runs out') ||
        s.contains('spent more than') ||
        s.contains('almost nothing') ||
        s.contains('late');
    final icon = warn
        ? Icons.warning_amber_rounded
        : s.contains('upload') || s.contains('statement') || s.contains('record')
            ? Icons.file_upload_outlined
            : s.contains('goal') || s.contains('reach')
                ? Icons.flag_outlined
                : s.contains('save') || s.contains('saving')
                    ? Icons.savings_outlined
                    : s.contains('bill') || s.contains('due') || s.contains('loan')
                        ? Icons.receipt_long_outlined
                        : s.contains('score')
                            ? Icons.speed_rounded
                            : Icons.lightbulb_outline_rounded;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: warn ? c.warnBg : c.lime, shape: BoxShape.circle),
          child: Icon(icon, size: 17, color: warn ? c.warn : c.onLime),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(height: 1.4)),
          ),
        ),
      ]),
    );
  }
}
