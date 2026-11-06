import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart' show categoryLabel, outsideCategories, spendingCategories;
import '../services/api.dart';
import '../state/app_state.dart';
import 'budget_warnings.dart';
import 'profile_screen.dart' show kes;

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
  'October', 'November', 'December'];

const _fixedLabels = {
  'housing': 'Rent and housing',
  'school_fees': 'School or university fees',
  'loan_repayment': 'Loan repayments',
  'other_commitments': 'Other commitments',
};

/// Step 5 of the journey: how should I spend this month? Limits from the /budget engine, against what has
/// actually been spent so far. Saving it makes next month's budget and forecast able to use it.
class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  Map<String, dynamic>? r;
  String? error;
  bool saving = false;

  Api get api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.budgetPlan();
      setState(() {
        r = d;
        error = null;
      });
    } catch (e) {
      setState(() => error = e is ApiException ? e.message : 'Something went wrong loading your budget.');
    }
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await api.saveBudget(r!['year'] as int, r!['month'] as int, (r!['plan'] as Map).cast<String, dynamic>());
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved as your budget for ${_monthNames[(r!['month'] as int) - 1]}')));
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (r == null) {
      return Center(
        child: error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: const Text('Try again')),
                ]),
              ),
      );
    }
    final saved = r!['saved'] as Map<String, dynamic>?;
    final plan = (saved ?? r!['plan']) as Map<String, dynamic>;
    final limits = (plan['budget'] as Map).cast<String, num>();
    final spent = (r!['spent_so_far'] as Map).cast<String, num>();
    final fresh = (r!['plan'] as Map<String, dynamic>);
    final changed = saved != null && saved['total'] != fresh['total'] ||
        saved != null && saved['budget'].toString() != fresh['budget'].toString();
    final fixedKeys = _fixedLabels.keys.where((k) => (limits[k] ?? 0) > 0).toList();
    final everyday = spendingCategories.keys
        .where((k) => !_fixedLabels.containsKey(k) && k != 'savings' && (limits[k] ?? 0) > 0)
        .toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Your budget for ${_monthNames[(r!['month'] as int) - 1]}', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Every shilling of your KES ${kes(plan['income'] as num).substring(4)} has a job. '
              'Your health right now: ${plan['state']}.', style: theme.textTheme.bodyMedium),
          ...((plan['notes'] as List?) ?? []).map((n) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(child: Text(n as String, style: theme.textTheme.bodySmall)),
                ]),
              )),
          if (((r!['warnings'] as List?) ?? []).isNotEmpty)
            BudgetWarnings(warnings: (r!['warnings'] as List).cast<Map<String, dynamic>>()),
          if (r!['safe_per_day'] != null && (r!['days_left'] as num) > 0)
            Card(
              margin: const EdgeInsets.only(top: 12),
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Safe to spend each day', style: theme.textTheme.titleSmall),
                  Text(kes(r!['safe_per_day'] as num), style: theme.textTheme.headlineMedium),
                  Text('${kes(r!['everyday_left'] as num)} left for everyday spending over the next '
                      '${r!['days_left']} day(s).', style: theme.textTheme.bodySmall),
                ]),
              ),
            ),
          const SizedBox(height: 12),
          if (fixedKeys.isNotEmpty)
            _Group(title: 'Set aside first', children: fixedKeys
                .map((k) => _Limit(label: _fixedLabels[k]!, limit: limits[k]!.toDouble(), spent: spent[k]?.toDouble()))
                .toList()),
          _Group(title: 'Savings', children: [
            _Limit(label: 'Savings', limit: (limits['savings'] ?? 0).toDouble(), spent: spent['savings']?.toDouble(),
                isSavings: true),
          ]),
          _Group(title: 'Everyday spending', children: everyday
              .map((k) => _Limit(label: spendingCategories[k]!, limit: limits[k]!.toDouble(),
                  spent: (spent[k] ?? 0).toDouble()))
              .toList()),
          if (outsideCategories.any((k) => (spent[k] ?? 0) > 0))
            _Group(title: 'Other spending this month', children: [
              Text('No budget line of its own; it comes out of your everyday money and the daily amount above.',
                  style: theme.textTheme.bodySmall),
              ...outsideCategories.where((k) => (spent[k] ?? 0) > 0).map((k) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(child: Text(categoryLabel(k))),
                      Text(kes(spent[k]!), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ]),
                  )),
            ]),
          const SizedBox(height: 16),
          if (saved == null)
            FilledButton.icon(
              onPressed: saving ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Use this as my budget for this month'),
            )
          else ...[
            Row(children: [
              Icon(Icons.verified, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(child: Text(r!['auto_saved'] == true
                  ? 'This is now your budget for this month. It updates when you press the button below.'
                  : 'This is your budget for this month.')),
            ]),
            if (changed)
              TextButton(
                onPressed: saving ? null : _save,
                child: const Text('Your situation has changed. Update to the latest plan'),
              ),
          ],
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );
}

class _Limit extends StatelessWidget {
  const _Limit({required this.label, required this.limit, this.spent, this.isSavings = false});
  final String label;
  final double limit;
  final double? spent;
  final bool isSavings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = spent ?? 0;
    final ratio = limit > 0 ? s / limit : 0.0;
    final color = isSavings
        ? theme.colorScheme.primary
        : ratio > 1
            ? theme.colorScheme.error
            : ratio > 0.85
                ? Colors.orange.shade800
                : theme.colorScheme.primary;
    final status = spent == null
        ? kes(limit)
        : isSavings
            ? '${kes(s)} saved of ${kes(limit)}'
            : ratio > 1
                ? '${kes(s)} of ${kes(limit)} · over by ${kes(s - limit)}'
                : '${kes(s)} of ${kes(limit)} · ${kes(limit - s)} left';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label)),
          Text(status, style: TextStyle(color: spent == null ? null : color, fontWeight: FontWeight.w600)),
        ]),
        if (spent != null) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: ratio.clamp(0, 1).toDouble(), minHeight: 8, color: color,
                backgroundColor: color.withValues(alpha: 0.15)),
          ),
        ],
      ]),
    );
  }
}
