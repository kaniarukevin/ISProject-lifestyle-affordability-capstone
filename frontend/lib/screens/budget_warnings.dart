import 'package:flutter/material.dart';

import '../models/transaction.dart' show categoryLabel;
import 'profile_screen.dart' show kes;

/// Budget lines running out this month (from the server: over the limit, or 80%+ used well ahead of the calendar).
/// Shown on the dashboard and at the top of the budget.
class BudgetWarnings extends StatelessWidget {
  const BudgetWarnings({super.key, required this.warnings});
  final List<Map<String, dynamic>> warnings;

  static String message(Map<String, dynamic> w) {
    final label = categoryLabel(w['category'] as String);
    final spent = w['spent_KES'] as num, limit = w['limit_KES'] as num;
    if (w['over'] == true) {
      return '$label: ${kes(spent)} spent, ${kes(spent - limit)} over the ${kes(limit)} budget.';
    }
    final pct = ((w['share'] as num) * 100).round();
    return '$label: ${kes(spent)} of ${kes(limit)} used ($pct%) with ${w['days_left']} day(s) to go. '
        'At this pace about ${kes(w['pace_KES'] as num)} by month end.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.speed, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Text('Budget check', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onErrorContainer)),
          ]),
          const SizedBox(height: 6),
          ...warnings.map((w) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• ${message(w)}', style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              )),
        ]),
      ),
    );
  }
}
