import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart' show categoryLabel;
import '../services/api.dart';
import '../state/app_state.dart';
import 'profile_screen.dart' show kes;
import 'why_score_sheet.dart';

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
          _StateCard(state: d['state'] as String, score: (d['score'] as num).toInt(),
              explained: d['score_explained'] as String?),
          ...((d['notes'] as List?) ?? []).map((n) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(n as String, style: theme.textTheme.bodySmall),
              )),
          if (((d['timeline'] as List?) ?? []).length >= 2)
            _Timeline(months: (d['timeline'] as List).cast<Map<String, dynamic>>(),
                summary: d['timeline_summary'] as String?),
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
                if (((latest['saved'] ?? 0) as num) > 0) _Line('Saved this month', kes(latest['saved'] as num)),
                if (((d['savings_balance'] ?? 0) as num) > 0) _Line('Total savings', kes(d['savings_balance'] as num)),
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
                if (fc['range'] is Map)
                  Text('Probably between ${kes((fc['range'] as Map)['low'] as num)} and '
                      '${kes((fc['range'] as Map)['high'] as num)} (8 months in 10 fall in this range).',
                      style: theme.textTheme.bodySmall),
                if (fc['note'] != null) Text(fc['note'] as String, style: theme.textTheme.bodySmall),
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
                    .map((e) => _Line(categoryLabel(e.key), kes(e.value))),
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
                      label: categoryLabel(e.key),
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
  const _StateCard({required this.state, required this.score, this.explained});
  final String state;
  final int score;
  final String? explained;

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
          Row(children: [
            Text('Score $score out of 100', style: theme.textTheme.bodySmall),
            if (explained != null)
              IconButton(
                icon: const Icon(Icons.info_outline, size: 18),
                tooltip: 'What does this mean?',
                onPressed: () => showDialog<void>(context: context, builder: (_) => AlertDialog(
                      title: const Text('Score and state'),
                      content: Text(explained!),
                      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
                    )),
              ),
            const Spacer(),
            TextButton(onPressed: () => showWhyScore(context), child: const Text('Why this score?')),
          ]),
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


/// Your financial state month by month: each month scored with only the data up to then, newest first.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.months, this.summary});
  final List<Map<String, dynamic>> months;
  final String? summary;

  Color _color(BuildContext context, String state) => switch (state) {
        'Stable' => Colors.green.shade700,
        'Strained' => Colors.orange.shade800,
        _ => Theme.of(context).colorScheme.error,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = months.reversed.toList();
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: ExpansionTile(
        title: const Text('Month by month'),
        subtitle: summary == null ? null : Text(summary!),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          // A strip of coloured dots, oldest to newest, for the trend at a glance.
          Row(children: months.map((m) => Expanded(
                child: Container(height: 10, margin: const EdgeInsets.symmetric(horizontal: 1),
                    color: _color(context, m['state'] as String)),
              )).toList()),
          const SizedBox(height: 8),
          ...rows.map((m) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  CircleAvatar(radius: 6, backgroundColor: _color(context, m['state'] as String)),
                  const SizedBox(width: 8),
                  SizedBox(width: 72, child: Text('${_months[(m['month'] as int) - 1]} ${m['year']}')),
                  Expanded(child: Text('${m['state']} · score ${m['score']}')),
                  Text('spent ${kes(m['spent'] as num)} of ${kes(m['income'] as num)}'
                      '${m['income_from'] == 'statement' ? '*' : ''}', style: theme.textTheme.bodySmall),
                ]),
              )),
          if (months.any((m) => m['income_from'] == 'statement'))
            Text('* money that actually arrived, from your statement', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
