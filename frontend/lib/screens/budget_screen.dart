import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/state_words.dart';
import '../widgets/model_note.dart';
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
/// What a month's state means for the budget, in plain words (wording audit, 10 Nov).
const _monthLooks = {
  'Stable': 'fine: there is room to save',
  'Strained': 'stretched: there is little room for extras',
  'Critical': 'hard: more is going out than comes in',
};

class BudgetView extends StatefulWidget {
  const BudgetView({super.key});

  @override
  State<BudgetView> createState() => _BudgetViewState();
}

class _BudgetViewState extends State<BudgetView> with ReloadOnChange {
  Map<String, dynamic>? r;
  bool _past = false;                 // this month, or past months against what was spent
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
    final switcher = Align(
      alignment: Alignment.centerLeft,
      child: Wrap(spacing: 8, children: [
        ChoiceChip(label: const Text('This month'), selected: !_past, showCheckmark: false,
            onSelected: (_) => setState(() => _past = false)),
        ChoiceChip(label: const Text('Past months'), selected: _past, showCheckmark: false,
            onSelected: (_) => setState(() => _past = true)),
      ]),
    );
    if (_past) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        switcher,
        const SizedBox(height: 16),
        const Expanded(child: _PastBudgets()),
      ]);
    }
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
              Text('${kesAmount(s)} spent of ${kesAmount(limit)}', style: const TextStyle(fontWeight: FontWeight.w600)),
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
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          switcher,
          const SizedBox(height: 16),
          if (d['safe_per_day'] != null && daysLeft > 0)
            Panel(
              color: c.lime,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('You can spend about', style: theme.textTheme.bodyLarge?.copyWith(color: c.onLime)),
                const SizedBox(height: 4),
                Text('${kesAmount(d['safe_per_day'] as num)} a day',
                    style: theme.textTheme.displaySmall?.copyWith(color: c.onLime, fontWeight: FontWeight.w700, letterSpacing: -1)),
                const SizedBox(height: 4),
                Text('until the end of the month and still keep to your plan: '
                    '${kesAmount(d['everyday_left'] as num)} left for everyday spending over the next $daysLeft '
                    'day${daysLeft == 1 ? '' : 's'}.', style: TextStyle(color: c.onLime)),
              ]),
            ),
          if (warnings.isNotEmpty) BudgetWarnings(warnings: warnings),
          const SizedBox(height: 20),
          CardColumns(minWidth: 340, children: [
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Your plan for ${monthNames[(d['month'] as int) - 1]}', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('Every shilling of your ${kesAmount(plan['income'] as num)} has a job. '
                    'This month looks ${_monthLooks[plan['state']] ?? stateLabel(plan['state'] as String).toLowerCase()}.',
                    style: TextStyle(color: c.muted)),
                const SizedBox(height: 16),
                DonutWithLegend(centerLabel: 'KES planned', slices: [
                  if (bills > 0) Slice('Paid first: rent and bills', bills.toDouble(), ChartColors.slot(context, 0)),
                  if (saving > 0) Slice('Savings', saving.toDouble(), ChartColors.slot(context, 2)),
                  if (everydayTotal > 0) Slice('Everyday: what is left to live on', everydayTotal.toDouble(), ChartColors.slot(context, 1)),
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
              Text('Tap a line to change its limit. The thin mark shows where you would be today if you spread it '
                  'evenly over the month.',
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
          const ModelNote(),
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
            Text('${kesAmount(spent!)} paid so far, of ', style: TextStyle(color: AppColors.of(context).muted)),
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
        Text('How this compares with a one-size-fits-all budget (50/30/20)', style: theme.textTheme.titleLarge),
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


/// Past months: each month's saved budget against what was really spent, line by line, how many lines were
/// kept, and what the budget changed that month. A month without a saved budget says so; none is rebuilt.
class _PastBudgets extends StatefulWidget {
  const _PastBudgets();

  @override
  State<_PastBudgets> createState() => _PastBudgetsState();
}

class _PastBudgetsState extends State<_PastBudgets> with ReloadOnChange {
  List<Map<String, dynamic>>? months;
  String? error;

  static const _names = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
    'October', 'November', 'December'];

  @override
  Future<void> reloadQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await context.read<AppState>().api.budgetHistory();
      if (mounted) setState(() => months = m);
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    if (months == null) {
      return error != null ? Center(child: Text(error!)) : const BusyCenter(['Loading your past budgets…']);
    }
    final withBudget = months!.where((m) => m['has_budget'] == true).toList();
    if (months!.isEmpty) {
      return Center(child: Text('No past months yet.', style: TextStyle(color: c.muted)));
    }
    final top = withBudget.fold<double>(0, (a, m) {
      final p = (m['planned'] as num).toDouble(), s = (m['spent'] as num).toDouble();
      return [a, p, s].reduce((x, y) => x > y ? x : y);
    });
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (withBudget.length >= 2)
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Planned against spent', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(_trend(withBudget), style: TextStyle(color: c.muted)),
                const SizedBox(height: 14),
                Row(children: [
                  _key(c.range, 'Planned'),
                  const SizedBox(width: 16),
                  _key(theme.colorScheme.onSurface, 'Spent'),
                  const SizedBox(width: 16),
                  _key(c.warn, 'Spent, over the plan'),
                ]),
                for (final m in withBudget.reversed)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(children: [
                      SizedBox(width: 44, child: Text(monthShort[(m['month'] as int) - 1], style: theme.textTheme.bodySmall)),
                      Expanded(
                        child: Column(children: [
                          _Bar(value: (m['planned'] as num).toDouble(), top: top, color: c.range),
                          const SizedBox(height: 3),
                          _Bar(value: (m['spent'] as num).toDouble(), top: top,
                              color: (m['spent'] as num) > (m['planned'] as num) ? c.warn : theme.colorScheme.onSurface),
                        ]),
                      ),
                      SizedBox(
                        width: 96,
                        child: Text(_diffText(m), textAlign: TextAlign.right, style: theme.textTheme.bodySmall),
                      ),
                    ]),
                  ),
              ]),
            ),
          for (final m in months!) ...[
            const SizedBox(height: 16),
            m['has_budget'] == true ? _month(context, m) : _noBudget(context, m),
          ],
        ],
      ),
    );
  }

  static Widget _key(Color color, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12)),
      ]);

  static String _diffText(Map<String, dynamic> m) {
    final d = (m['spent'] as num) - (m['planned'] as num);
    return d > 0 ? '${kesAmount(d)} over' : '${kesAmount(-d)} under';
  }

  /// One plain sentence about the months shown: getting closer to the plan, or drifting away.
  static String _trend(List<Map<String, dynamic>> m) {
    final kept = m.map((x) => (x['kept'] as num) / ((x['everyday_lines'] as num) == 0 ? 1 : x['everyday_lines'] as num)).toList();
    final recent = kept.first, oldest = kept.last;
    final over = m.where((x) => (x['spent'] as num) > (x['planned'] as num)).length;
    final keep = recent > oldest ? 'You are keeping more of your lines than before.'
        : recent < oldest ? 'You are keeping fewer of your lines than before.' : 'You keep about the same share of your lines.';
    return '$over of ${m.length} months went over the plan. $keep';
  }

  Widget _noBudget(BuildContext context, Map<String, dynamic> m) {
    final c = AppColors.of(context);
    return Panel(
      child: Row(children: [
        Expanded(
          child: Text('${_names[(m['month'] as int) - 1]} ${m['year']}', style: Theme.of(context).textTheme.titleMedium),
        ),
        Flexible(
          child: Text('No budget for that month: Tosha keeps a month\'s budget from the first time you open it.',
              textAlign: TextAlign.right, style: TextStyle(color: c.muted)),
        ),
      ]),
    );
  }

  Widget _month(BuildContext context, Map<String, dynamic> m) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final lines = (m['lines'] as List).cast<Map<String, dynamic>>();
    final kept = m['kept'] as int, all = m['everyday_lines'] as int;
    final notes = (m['notes'] as List).cast<String>();
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('${_names[(m['month'] as int) - 1]} ${m['year']}', style: theme.textTheme.titleLarge)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: kept == all && all > 0 ? c.lime : c.field, borderRadius: BorderRadius.circular(16)),
            child: Text('$kept of $all lines kept',
                style: TextStyle(fontWeight: FontWeight.w700, color: kept == all && all > 0 ? c.onLime : null)),
          ),
        ]),
        const SizedBox(height: 6),
        Text('Planned ${kesAmount(m['planned'] as num)} · spent ${kesAmount(m['spent'] as num)} · '
            'saved ${kesAmount(m['saved'] as num)} of ${kesAmount(m['savings_planned'] as num)} planned'
            '${(m['unsorted'] as num) > 0 ? ' · ${kesAmount(m['unsorted'] as num)} not sorted' : ''}',
            style: TextStyle(color: c.muted)),
        const SizedBox(height: 10),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(_fixedLabels[l['category']] ?? categoryLabel(l['category'] as String),
                    style: const TextStyle(fontWeight: FontWeight.w600))),
                Text('${kesAmount(l['spent'] as num)} of ${kesAmount(l['budget'] as num)}'),
                const SizedBox(width: 10),
                SizedBox(
                  width: 92,
                  child: Text(
                    (l['diff'] as num) > 0 ? '${kesAmount(l['diff'] as num)} over' : '${kesAmount(-(l['diff'] as num))} under',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: (l['diff'] as num) > 0 ? c.warn : c.muted, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              _Bar(value: (l['spent'] as num).toDouble(), top: [(l['budget'] as num).toDouble(), (l['spent'] as num).toDouble()]
                  .reduce((a, b) => a > b ? a : b), color: (l['diff'] as num) > 0 ? c.warn : ChartColors.category(context, l['category'] as String),
                  track: true),
            ]),
          ),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('What the budget changed that month', style: theme.textTheme.titleSmall),
          for (final n in notes)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $n', style: TextStyle(color: c.muted))),
        ],
      ]),
    );
  }
}

/// A plain horizontal bar, as long as value/top; with [track], a grey track behind it shows the full line.
class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.top, required this.color, this.track = false});
  final double value, top;
  final Color color;
  final bool track;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final w = top <= 0 ? 0.0 : (box.maxWidth * value / top).clamp(value > 0 ? 4.0 : 0.0, box.maxWidth);
        return Container(
          height: 10,
          alignment: Alignment.centerLeft,
          decoration: track ? BoxDecoration(color: AppColors.of(context).range, borderRadius: BorderRadius.circular(5)) : null,
          child: Container(width: w, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5))),
        );
      });
}
