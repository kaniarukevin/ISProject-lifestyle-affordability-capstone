import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart' show spendingCategories;
import '../services/api.dart';
import '../state/app_state.dart';
import 'profile_screen.dart' show kes;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Step 4 of the journey: how am I doing? State, score, last month, and next month's forecast.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.onAddSpending});
  final VoidCallback? onAddSpending;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Map<String, dynamic>? o;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<AppState>().api.overview();
      setState(() {
        o = d;
        error = null;
      });
    } catch (e) {
      // Any failure must end the spinner and say what happened.
      setState(() => error = e is ApiException ? e.message : 'Something went wrong loading your dashboard.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (error != null && o == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () {
              setState(() => error = null);
              _load();
            }, child: const Text('Try again')),
          ]),
        ),
      );
    }
    if (o == null) return const Center(child: CircularProgressIndicator());
    if (o!['has_data'] != true) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.insights, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('Your dashboard appears once you record some spending.', textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (widget.onAddSpending != null)
              FilledButton(onPressed: widget.onAddSpending, child: const Text('Add spending')),
          ]),
        ),
      );
    }
    final d = o!;
    final latest = d['latest'] as Map<String, dynamic>;
    final fc = d['forecast'] as Map<String, dynamic>;
    final byCat = (latest['by_category'] as Map).cast<String, num>().entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final history = (d['history'] as List).cast<Map<String, dynamic>>();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StateCard(state: d['state'] as String, score: (d['score'] as num).toInt()),
          ...((d['notes'] as List?) ?? []).map((n) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(n as String, style: theme.textTheme.bodySmall),
              )),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_months[(latest['month'] as int) - 1]} ${latest['year']}${latest['partial'] == true ? ' so far' : ''}',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                _Line('Money in', kes(d['income_monthly'] as num)),
                _Line('Spent', kes(latest['spent'] as num)),
                if (((latest['one_off'] ?? 0) as num) > 0)
                  _Line('One-off purchases (not counted)', kes(latest['one_off'] as num)),
                const Divider(),
                _Line(latest['partial'] == true ? 'Left so far' : 'Left over', kes(latest['left_over'] as num),
                    color: (latest['left_over'] as num) < 0 ? theme.colorScheme.error : theme.colorScheme.primary),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Expected spending in ${_months[(fc['month'] as int) - 1]}', style: theme.textTheme.titleSmall),
                Text(kes(fc['total'] as num), style: theme.textTheme.headlineMedium),
                if (latest['partial'] == true && (fc['total'] as num) > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      LinearProgressIndicator(
                        value: ((latest['spent'] as num) / (fc['total'] as num)).clamp(0, 1).toDouble(), minHeight: 8),
                      const SizedBox(height: 4),
                      Text('${kes(latest['spent'] as num)} spent so far '
                          '(${((latest['spent'] as num) * 100 / (fc['total'] as num)).round()}% of what is expected)'),
                    ]),
                  ),
                Text(fc['method'] == 'trailing_median'
                    ? 'Based on your usual spending over ${fc['months_used']} month(s).'
                    : 'Based on your budget and your usual spending.',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                ...((fc['breakdown'] as Map).cast<String, num>().entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .take(5)
                    .map((e) => _Line(spendingCategories[e.key] ?? e.key, kes(e.value))),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Where your money went', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ...byCat.map((e) => _Bar(
                      label: spendingCategories[e.key] ?? e.key,
                      value: e.value.toDouble(),
                      max: byCat.first.value.toDouble(),
                    )),
              ]),
            ),
          ),
          if (history.length > 1) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Spending by month', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  ...history.map((h) => _Bar(
                        label: '${_months[(h['month'] as int) - 1]} ${h['year']}',
                        value: (h['spent'] as num).toDouble(),
                        max: history.map((x) => (x['spent'] as num).toDouble()).reduce((a, b) => a > b ? a : b),
                      )),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({required this.state, required this.score});
  final String state;
  final int score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, text) = switch (state) {
      'Stable' => (Colors.green.shade700, 'You are spending within your means.'),
      'Strained' => (Colors.orange.shade800, 'Money is tight. Small changes now will help.'),
      _ => (theme.colorScheme.error, 'You are spending more than you can sustain. Let\'s fix that first.'),
    };
    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.favorite, color: color),
            const SizedBox(width: 8),
            Text('Financial health: $state', style: theme.textTheme.titleMedium?.copyWith(color: color)),
          ]),
          const SizedBox(height: 4),
          Text(text),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: score / 100, minHeight: 10, color: color,
                backgroundColor: color.withValues(alpha: 0.15)),
          ),
          const SizedBox(height: 4),
          Text('Score $score out of 100', style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.color});
  final String label, value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ]),
      );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.value, required this.max});
  final String label;
  final double value, max;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(label)), Text(kes(value))]),
          const SizedBox(height: 2),
          LinearProgressIndicator(value: max > 0 ? value / max : 0, minHeight: 6),
        ]),
      );
}
