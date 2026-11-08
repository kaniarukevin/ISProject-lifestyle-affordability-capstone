import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart' show categoryLabel, outsideCategories, spendingCategories;
import '../services/api.dart';
import '../state/app_state.dart';
import '../state/reload_on_change.dart';
import '../theme/app_theme.dart';
import '../widgets/busy_words.dart';
import '../widgets/charts.dart';
import '../widgets/format.dart';
import '../widgets/panel.dart';
import 'budget_warnings.dart';

const _fixedLabels = {
  'housing': 'Rent',
  'school_fees': 'School fees',
  'loan_repayment': 'Loan repayments',
  'other_commitments': 'Other bills (chama, insurance, support)',
};

/// The budget opened on its own page (kept for links from elsewhere); the tab shows [BudgetView].
class BudgetScreen extends StatelessWidget {
  const BudgetScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your budget')),
        body: const SafeArea(child: Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: BudgetView())),
      );
}

/// This month's budget: what is safe to spend today, how the money is split, each everyday line against the
/// month's pace, and what changed this month. Any everyday line can be set by hand; the others rebalance, savings
/// and bills stay, and the choice is remembered next month.
class BudgetView extends StatefulWidget {
  const BudgetView({super.key});

  @override
  State<BudgetView> createState() => _BudgetViewState();
}

class _BudgetViewState extends State<BudgetView> with ReloadOnChange {
  Map<String, dynamic>? r;
  String? error;

  Api get api => context.read<AppState>().api;

  @override
  Future<void> reloadQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.budgetPlan();
      if (mounted) {
        setState(() {
          r = d;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e is ApiException ? e.message : 'Something went wrong loading your budget.');
    }
  }

  Future<void> _edit(String cat, num limit, num spent) async {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final ctl = TextEditingController(text: limit.round().toString());
    String? problem;
    final amount = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(categoryLabel(cat), style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('Recommended: ${kesAmount(limit)} a month. ${kesAmount(spent)} spent so far.',
                style: TextStyle(color: c.muted)),
            const SizedBox(height: 10),
            Text('Why this amount? It blends what you usually spend here with what households like yours spend, '
                'after rent, bills and 10% savings.',
                style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            const SizedBox(height: 16),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Your limit for ${categoryLabel(cat).toLowerCase()}',
                  prefixText: 'KES ', errorText: problem),
            ),
            const SizedBox(height: 8),
            Text('The other everyday lines adjust so your total still fits. Savings and bills stay as they are. '
                'Tosha keeps this next month too.',
                style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.lime, foregroundColor: c.onLime),
              onPressed: () {
                final v = double.tryParse(ctl.text.replaceAll(',', '').trim());
                if (v == null || !v.isFinite || v < 0 || v > 100000000) {
                  setSheet(() => problem = 'Enter an amount in shillings.');
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: const Text('Save'),
            ),
          ]),
        ),
      ),
    );
    if (amount == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final d = await api.editBudgetLine(cat, amount);
      if (mounted) setState(() => r = d);
      messenger.showSnackBar(SnackBar(content: Text('${categoryLabel(cat)} set to ${kesAmount(amount)}')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _reset() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final d = await api.resetBudget();
      if (mounted) setState(() => r = d);
      messenger.showSnackBar(const SnackBar(content: Text('Back to the recommended budget')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    if (r == null) {
      return error == null
          ? const BusyCenter(budgetWords)
          : Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(error!, textAlign: TextAlign.center)));
    }
    final d = r!;
    final plan = (d['plan'] as Map).cast<String, dynamic>();
    final lines = ((d['lines'] ?? plan['budget']) as Map).cast<String, num>();
    final spent = (d['spent_so_far'] as Map).cast<String, num>();
    final everyday = ((d['everyday'] as List?) ?? []).cast<String>().where((k) => (lines[k] ?? 0) > 0 || (spent[k] ?? 0) > 0).toList()
      ..sort((a, b) => (lines[b] ?? 0).compareTo(lines[a] ?? 0));
    final edited = ((d['edited'] as List?) ?? []).cast<String>().toSet();
    final fixed = _fixedLabels.keys.where((k) => (lines[k] ?? 0) > 0).toList();
    final dim = (d['days_in_month'] as num?)?.toInt() ?? 30;
    final daysLeft = (d['days_left'] as num?)?.toInt() ?? 0;
    final pace = ((dim - daysLeft + 1) / dim).clamp(0.0, 1.0);
    final bills = fixed.fold<num>(0, (a, k) => a + (lines[k] ?? 0));
    final saving = lines['savings'] ?? 0;
    final everydayTotal = everyday.fold<num>(0, (a, k) => a + (lines[k] ?? 0));
    final notes = ((plan['notes'] as List?) ?? []).cast<String>();
    final warnings = ((d['warnings'] as List?) ?? []).cast<Map<String, dynamic>>();
    final outside = outsideCategories.where((k) => (spent[k] ?? 0) > 0 && !lines.containsKey(k)).toList();
    const monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
      'October', 'November', 'December'];

    Widget limitRow(String k) {
      final limit = lines[k] ?? 0, s = spent[k] ?? 0;
      final over = s > limit && limit > 0;
      final ahead = !over && s > limit * pace + (limit * 0.1 > 200 ? limit * 0.1 : 200);
      final color = over || ahead ? c.warn : ChartColors.category(context, k);
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _edit(k, limit, s),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(spendingCategories[k] ?? categoryLabel(k), style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (edited.contains(k))
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(10)),
                      child: Text('Set by you', style: theme.textTheme.bodySmall),
                    ),
                ]),
              ),
              Text('${kesAmount(s)} of ${kesAmount(limit)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Icon(Icons.edit_rounded, size: 16, color: c.muted),
            ]),
            const SizedBox(height: 8),
            PaceBar(spent: s.toDouble(), limit: limit.toDouble(), pace: pace, color: color),
            const SizedBox(height: 6),
            Text(
                over
                    ? '${kesAmount(s - limit)} over'
                    : ahead
                        ? '${kesAmount(s - limit * pace)} ahead of pace · ${kesAmount(limit - s)} left'
                        : '${kesAmount(limit - s)} left',
                style: theme.textTheme.bodySmall?.copyWith(color: over || ahead ? c.warn : c.muted)),
          ]),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (d['safe_per_day'] != null && daysLeft > 0)
            Panel(
              color: c.lime,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Safe to spend today', style: theme.textTheme.bodyLarge?.copyWith(color: c.onLime)),
                const SizedBox(height: 4),
                Text(kesAmount(d['safe_per_day'] as num),
                    style: theme.textTheme.displaySmall?.copyWith(color: c.onLime, fontWeight: FontWeight.w700, letterSpacing: -1)),
                const SizedBox(height: 4),
                Text('${kesAmount(d['everyday_left'] as num)} left for everyday spending over the next $daysLeft '
                    'day${daysLeft == 1 ? '' : 's'}.', style: TextStyle(color: c.onLime)),
              ]),
            ),
          if (warnings.isNotEmpty) BudgetWarnings(warnings: warnings),
          const SizedBox(height: 20),
          CardRow(minWidth: 340, children: [
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Your plan for ${monthNames[(d['month'] as int) - 1]}', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('Every shilling of your ${kesAmount(plan['income'] as num)} has a job. '
                    'This month looks ${(plan['state'] as String).toLowerCase()}.',
                    style: TextStyle(color: c.muted)),
                const SizedBox(height: 16),
                DonutWithLegend(centerLabel: 'KES planned', slices: [
                  if (bills > 0) Slice('Rent and bills', bills.toDouble(), ChartColors.slot(context, 0)),
                  if (saving > 0) Slice('Savings', saving.toDouble(), ChartColors.slot(context, 2)),
                  if (everydayTotal > 0) Slice('Everyday spending', everydayTotal.toDouble(), ChartColors.slot(context, 1)),
                ]),
              ]),
            ),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('What changed this month', style: theme.textTheme.titleLarge),
                const SizedBox(height: 10),
                if (notes.isEmpty) Text('Nothing special: a usual month.', style: TextStyle(color: c.muted)),
                for (final n in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 7, right: 10),
                        child: CircleAvatar(radius: 3, backgroundColor: theme.colorScheme.onSurface),
                      ),
                      Expanded(child: Text(n)),
                    ]),
                  ),
              ]),
            ),
          ]),
          const SizedBox(height: 20),
          _VersusRule(income: (plan['income'] as num).toDouble(), lines: lines),
          const SizedBox(height: 20),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text('Everyday spending', style: theme.textTheme.titleLarge)),
                if (edited.isNotEmpty) TextButton(onPressed: _reset, child: const Text('Back to recommended')),
              ]),
              Text('Tap a line to set your own limit. The black mark shows where spending should be by today.',
                  style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
              const SizedBox(height: 8),
              for (final k in everyday) limitRow(k),
            ]),
          ),
          const SizedBox(height: 20),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Set aside first', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final k in fixed) _Plain(_fixedLabels[k]!, lines[k]!, spent[k]),
              _Plain('Savings', saving, spent['savings']),
            ]),
          ),
          if (outside.isNotEmpty) ...[
            const SizedBox(height: 20),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Other spending this month', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('No line of its own: it comes out of your everyday money and the daily amount above.',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                const SizedBox(height: 8),
                for (final k in outside) _Plain(categoryLabel(k), spent[k]!, null),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

class _Plain extends StatelessWidget {
  const _Plain(this.label, this.amount, this.spent);
  final String label;
  final num amount;
  final num? spent;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label)),
          if (spent != null)
            Text('${kesAmount(spent!)} paid of ', style: TextStyle(color: AppColors.of(context).muted)),
          Text(kesAmount(amount), style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );
}


/// Your budget against the 50/30/20 rule for the same income: the contrast with fixed-percentage budgeting,
/// on the user's own numbers. Needs: bills, food, transport, power, airtime, health. Wants: fun, money sent,
/// shopping, personal care.
class _VersusRule extends StatelessWidget {
  const _VersusRule({required this.income, required this.lines});
  final double income;
  final Map<String, num> lines;

  static const _needs = ['housing', 'school_fees', 'loan_repayment', 'other_commitments', 'food_groceries',
    'transport', 'utilities', 'airtime_data', 'health'];
  static const _wants = ['entertainment', 'mobile_money_transfers', 'shopping', 'personal_care'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    double sum(List<String> keys) => keys.fold<double>(0, (a, k) => a + (lines[k] ?? 0).toDouble());
    final rows = [
      ('Needs', 0.5 * income, sum(_needs)),
      ('Wants', 0.3 * income, sum(_wants)),
      ('Savings', 0.2 * income, (lines['savings'] ?? 0).toDouble()),
    ];
    final top = rows.fold<double>(0, (a, r) => [a, r.$2, r.$3].reduce((x, y) => x > y ? x : y));
    Widget bar(double v, Color color) => LayoutBuilder(
          builder: (context, box) => Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: top <= 0 ? 0 : (box.maxWidth * v / top).clamp(4.0, box.maxWidth),
              height: 10,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5)),
            ),
          ),
        );
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Your budget vs the 50/30/20 rule', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('Fixed rules give everyone the same percentages. Tosha starts from your bills, your own spending and '
            'how your month is going, so the split is yours.', style: TextStyle(color: c.muted)),
        const SizedBox(height: 14),
        Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c.range, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 6),
          Text('50/30/20', style: theme.textTheme.bodySmall),
          const SizedBox(width: 16),
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 6),
          Text('Your Tosha budget', style: theme.textTheme.bodySmall),
        ]),
        for (final (label, rule, mine) in rows)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
                Text('${kesAmount(rule)} → ', style: TextStyle(color: c.muted)),
                Text(kesAmount(mine), style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 6),
              bar(rule, c.range),
              const SizedBox(height: 4),
              bar(mine, c.lime),
            ]),
          ),
      ]),
    );
  }
}
