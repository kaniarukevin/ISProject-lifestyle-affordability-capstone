import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart' show categoryLabel;
import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/format.dart';
import '../widgets/panel.dart';
import 'budget_screen.dart';

/// Forecast and budget: the next three months at your usual pace (the plain, validated forecast), what to put
/// aside, and each budget line against what you usually spend (GET /me/budget-forecast).
class ForecastScreen extends StatefulWidget {
  const ForecastScreen({super.key});

  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  Map<String, dynamic>? f;
  String? error;
  int _month = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<AppState>().api.budgetForecast();
      if (!mounted) return;
      setState(() {
        f = d;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e is ApiException ? e.message : 'Something went wrong loading the forecast.');
    }
  }

  Future<void> _editBudget() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(appBar: AppBar(title: const Text('Your budget')), body: const BudgetScreen())));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    if (error != null && f == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(error!, textAlign: TextAlign.center)),
          OutlinedButton(onPressed: () {
            setState(() => error = null);
            _load();
          }, child: const Text('Try again')),
        ]),
      );
    }
    if (f == null) return const Center(child: CircularProgressIndicator());
    final d = f!;
    if (d['has_data'] != true) {
      return Center(
        child: Text('The forecast appears once there are some records.', style: theme.textTheme.bodyLarge),
      );
    }
    final months = (d['months'] as List).cast<Map<String, dynamic>>();
    final sel = months[_month.clamp(0, months.length - 1)];
    final lines = (sel['lines'] as List).cast<Map<String, dynamic>>()
      ..sort((a, b) => (b['budget'] as num).compareTo(a['budget'] as num));
    final putAside = d['put_aside'] as Map<String, dynamic>?;
    final path = (d['savings_path'] as List).cast<Map<String, dynamic>>();
    final notes = (d['notes'] as List).cast<String>();
    final planned = lines.fold<num>(0, (s, l) => s + (l['budget'] as num));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Text(d['based_on'] == 'setup'
              ? 'Based on the rough figures you gave at setup'
              : 'Based on ${d['months_used']} month(s) of your records',
              style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
          const SizedBox(height: 16),
          CardRow(minWidth: 230, children: [
            for (var i = 0; i < months.length; i++)
              _MonthCard(month: months[i], first: i == 0, selected: i == _month, onTap: () => setState(() => _month = i)),
          ]),
          if (putAside != null) ...[
            const SizedBox(height: 20),
            Panel(
              color: c.lime,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.savings_rounded, color: Color(0xFF111111)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Put aside ${kesAmount(putAside['per_month_KES'] as num)} a month for the next '
                    '${putAside['months']} month(s), and ${monthLong[(putAside['for_month'] as int) - 1]} is covered.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFF111111), fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          CardRow(minWidth: 340, flex: const [2, 1], children: [
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    Text('${monthLong[(sel['month'] as int) - 1]} budget', style: theme.textTheme.titleLarge),
                    Text('KES ${money(planned)} for everyday spending',
                        style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: Text('Category', style: theme.textTheme.bodySmall?.copyWith(color: c.muted))),
                  SizedBox(width: 90, child: Text('Budget', textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(color: c.muted))),
                  SizedBox(width: 110, child: Text('You usually spend', textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(color: c.muted))),
                ]),
                for (final l in lines) ...[
                  const Divider(height: 20),
                  Row(children: [
                    Expanded(child: Text(categoryLabel(l['category'] as String),
                        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600))),
                    SizedBox(width: 90, child: Text(money(l['budget'] as num), textAlign: TextAlign.right,
                        style: theme.textTheme.bodyLarge)),
                    SizedBox(
                      width: 110,
                      child: Text(money(l['usual'] as num), textAlign: TextAlign.right,
                          style: theme.textTheme.bodyLarge?.copyWith(
                              color: (l['gap'] as num) > 0 ? c.warn : c.muted,
                              fontWeight: (l['gap'] as num) > 0 ? FontWeight.w600 : null)),
                    ),
                  ]),
                ],
                const SizedBox(height: 14),
                Text('Amber: you usually spend more than the budget here. Rent, loans and fees are taken out first.',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(backgroundColor: c.field, foregroundColor: theme.colorScheme.onSurface),
                    onPressed: _editBudget,
                    child: Text(d['budget_source'] == 'saved' ? 'Change my budget' : 'Review and save my budget'),
                  ),
                ),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (path.isNotEmpty)
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Your savings', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text('By the end of ${monthLong[(path.last['month'] as int) - 1]}, '
                        'from ${kesAmount(d['savings_now'] as num)} now',
                        style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                    const SizedBox(height: 14),
                    _SavingsBar(label: 'On budget', value: path.last['on_budget'] as num,
                        max: _max(path), color: theme.colorScheme.onSurface),
                    const SizedBox(height: 12),
                    _SavingsBar(label: 'At your usual pace', value: path.last['usual_pace'] as num,
                        max: _max(path), color: c.muted),
                  ]),
                ),
              const SizedBox(height: 20),
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('What this means', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 10),
                  for (final n in notes)
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(n, style: theme.textTheme.bodyMedium)),
                ]),
              ),
            ]),
          ]),
        ],
      ),
    );
  }

  static num _max(List<Map<String, dynamic>> path) => path
      .map((p) => [(p['on_budget'] as num).abs(), (p['usual_pace'] as num).abs()])
      .expand((x) => x)
      .fold<num>(1, (a, b) => a > b ? a : b);
}

class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.month, required this.first, required this.selected, required this.onTap});
  final Map<String, dynamic> month;
  final bool first;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final left = month['left_over'] as num;
    final short = left < 0;
    final fees = (month['school_fees'] ?? 0) as num;
    final range = month['range'] as Map?;
    final fg = short ? c.warn : null;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: short ? c.warnBg : theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: selected ? BorderSide(color: theme.colorScheme.onSurface, width: 2) : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: monthLong[(month['month'] as int) - 1],
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                if (first) TextSpan(text: ' · this month', style: TextStyle(color: c.muted)),
              ]), style: theme.textTheme.bodyLarge),
              const SizedBox(height: 12),
              Text(short ? 'Expected short' : 'Expected left', style: theme.textTheme.bodyMedium?.copyWith(color: fg ?? c.muted)),
              Text(money(left),
                  style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1, color: fg)),
              const SizedBox(height: 4),
              Text(
                'Spending ${money(month['spending'] as num)}'
                '${fees > 0 ? ' · school fees ${money(fees)}' : range != null ? ' · likely ${money(range['low'] as num)} to ${money(range['high'] as num)}' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(color: fg ?? c.muted),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SavingsBar extends StatelessWidget {
  const _SavingsBar({required this.label, required this.value, required this.max, required this.color});
  final String label;
  final num value;
  final num max;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        Text(money(value), style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700, color: value < 0 ? c.warn : null)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: LinearProgressIndicator(
          value: value <= 0 ? 0 : (value / max).clamp(0, 1).toDouble(),
          minHeight: 10,
          color: color,
          backgroundColor: c.range,
        ),
      ),
    ]);
  }
}
