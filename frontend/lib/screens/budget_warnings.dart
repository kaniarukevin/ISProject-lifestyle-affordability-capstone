import 'package:flutter/material.dart';

import '../models/transaction.dart' show categoryLabel;
import '../theme/app_theme.dart';
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
    final c = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.speed_rounded, color: c.warn),
          const SizedBox(width: 8),
          Text('Running ahead', style: TextStyle(color: c.warn, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        ...warnings.map((w) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('• ${message(w)}', style: TextStyle(color: c.warn)),
            )),
      ]),
    );
  }
}
