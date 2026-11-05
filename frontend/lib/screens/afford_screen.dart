import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/presets.dart';
import '../models/transaction.dart' show categoryLabel;
import '../services/api.dart';
import '../state/app_state.dart';
import 'profile_screen.dart' show kes;
import 'why_score_sheet.dart';

/// The heart of the project: test a lifestyle change on your own numbers before committing to it.
class AffordScreen extends StatefulWidget {
  const AffordScreen({super.key});

  @override
  State<AffordScreen> createState() => _AffordScreenState();
}

class _AffordScreenState extends State<AffordScreen> {
  List<Map<String, dynamic>> history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final h = await context.read<AppState>().api.scenarios();
      if (mounted) setState(() => history = h);
    } catch (_) {/* history is optional */}
  }

  Future<void> _open(Preset p) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => _AskScreen(preset: p)));
    if (result != null) _loadHistory();
  }

  Widget _grid(String title, List<Preset> presets) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: presets
                .map((p) => SizedBox(
                      width: 170,
                      child: Card(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _open(p),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Icon(p.icon, color: Theme.of(context).colorScheme.primary),
                              const SizedBox(height: 8),
                              Text(p.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text(p.subtitle, style: Theme.of(context).textTheme.bodySmall),
                            ]),
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Can I afford it?', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Test a lifestyle change on your own numbers before you commit. You get a score, a clear answer, '
              'the reasons, and what you could change to make it work.', style: theme.textTheme.bodySmall),
          _grid('For anyone', anyonePresets),
          _grid('Family and home', familyPresets),
          _grid('Students', studentPresets),
          if (history.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 24, bottom: 8),
              child: Text('Your past checks', style: theme.textTheme.titleMedium),
            ),
            ...history.take(10).map((h) {
              final r = (h['result'] as Map).cast<String, dynamic>();
              final id = h['id'] as int;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _VerdictDot(verdict: r['verdict'] as String? ?? ''),
                title: Text((r['title'] ?? 'Check') as String),
                subtitle: Text('${r['verdict']}${r['score_after'] != null ? ' · score ${r['score_after']}' : ''}'
                    '${r['applied'] != null ? ' · going ahead' : ''}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete this check',
                  onPressed: () async {
                    await context.read<AppState>().api.deleteScenario(id);
                    _loadHistory();
                  },
                ),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ResultScreen(result: {...r, 'id': id},
                          choice: (h['request'] as Map?)?.cast<String, dynamic>())));
                  _loadHistory();
                },
              );
            }),
          ],
        ],
      ),
    );
  }
}

class _AskScreen extends StatefulWidget {
  const _AskScreen({required this.preset});
  final Preset preset;

  @override
  State<_AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<_AskScreen> {
  late final Map<String, TextEditingController> ctl = {
    for (final f in widget.preset.fields)
      f.key: TextEditingController(text: f.initial == null ? '' : f.initial!.round().toString()),
  };
  bool busy = false;
  String? error;

  @override
  void dispose() {
    for (final c in ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _check() async {
    final values = <String, num>{};
    for (final f in widget.preset.fields) {
      final v = num.tryParse(ctl[f.key]!.text.replaceAll(',', '').trim());
      if (v == null || (v < 0 && !f.allowNegative)) {
        setState(() => error = 'Fill in "${f.label}" with a number.');
        return;
      }
      values[f.key] = v;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final choice = buildChoice(widget.preset, values);
      final r = await context.read<AppState>().api.afford(choice);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen(result: r, choice: choice)));
      if (mounted) Navigator.of(context).pop(r);
    } on ApiException catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.preset;
    return Scaffold(
      appBar: AppBar(title: Text(p.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(p.subtitle, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          ...p.fields.map((f) => TextField(
                controller: ctl[f.key],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: f.label, helperText: f.hint),
              )),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : _check,
            child: busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Can I afford it?'),
          ),
        ],
      ),
    );
  }
}

Color verdictColor(BuildContext context, String verdict) => switch (verdict) {
      'Affordable' => Colors.green.shade700,
      'Stretch' => Colors.orange.shade800,
      _ => Theme.of(context).colorScheme.error,
    };

class _VerdictDot extends StatelessWidget {
  const _VerdictDot({required this.verdict});
  final String verdict;

  @override
  Widget build(BuildContext context) =>
      CircleAvatar(radius: 8, backgroundColor: verdictColor(context, verdict));
}

/// The answer, in the order a person needs it: verdict, why, what would make it work.
class ResultScreen extends StatelessWidget {
  const ResultScreen({super.key, required this.result, this.choice});
  final Map<String, dynamic> result;
  final Map<String, dynamic>? choice;     // what was asked, so "Why?" can explain the score after it

  String _cat(String k) => categoryLabel(k);

  Widget _cutPlan(BuildContext context, String title, dynamic plan) {
    if (plan == null) return const SizedBox.shrink();
    if (plan is String) return _Box(title: title, children: [Text(plan)]);
    final p = (plan as Map).cast<String, dynamic>();
    final cuts = (p['monthly_cuts_KES'] as Map).cast<String, num>();
    return _Box(title: title, children: [
      Text('Cut each of these by about ${p['cut_each_by_percent']}%:'),
      ...cuts.entries.where((e) => e.value > 0).map((e) => Text('• ${_cat(e.key)}: ${kes(e.value)} less a month')),
      const SizedBox(height: 4),
      Text('That frees ${kes(p['total_cut_KES'] as num)} a month and leaves ${kes(p['left_over_after_KES'] as num)}.'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verdict = (result['verdict'] ?? '') as String;
    final color = verdictColor(context, verdict);
    final before = result['score_before'] as num?;
    final after = result['score_after'] as num?;
    final cut = result['what_to_cut'];
    return Scaffold(
      appBar: AppBar(title: const Text('Your answer')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text((result['title'] ?? '') as String, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            color: color.withValues(alpha: 0.1),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Text(verdict, style: theme.textTheme.headlineMedium?.copyWith(color: color, fontWeight: FontWeight.bold)),
                if (before != null && after != null) ...[
                  const SizedBox(height: 8),
                  Text(before == after ? 'Affordability score: stays at $after out of 100'
                      : 'Affordability score: $before → $after out of 100'),
                  // The score looks at recent months; when the whole year lowered the verdict, say so right here
                  // (found on real data, 5 Nov: "100 → 100" next to "Stretch" read like a mistake).
                  if ((result['track_record'] as Map?)?['lowered_verdict'] == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Lowered from Affordable because of your track record over the year (see why below).',
                          style: theme.textTheme.bodySmall?.copyWith(color: color), textAlign: TextAlign.center),
                    ),
                  if (result['score_note'] != null)
                    Text(result['score_note'] as String, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: after / 100, minHeight: 10, color: color,
                        backgroundColor: color.withValues(alpha: 0.15)),
                  ),
                  if (choice != null)
                    TextButton(onPressed: () => showWhyScore(context, choice: choice),
                        child: const Text('Why this score?')),
                ],
              ]),
            ),
          ),
          if (result['instalment_per_month_KES'] != null)
            _Box(title: 'Two ways to pay', children: [
              Text('In instalments: ${kes(result['instalment_per_month_KES'] as num)} a month'
                  '${result['lasts_months'] != null ? ' for ${result['lasts_months']} month(s)' : ''}'
                  '${result['total_paid_KES'] != null ? ', ${kes(result['total_paid_KES'] as num)} in total' : ''}.'),
              if (result['pay_from_savings'] is Map && (result['pay_from_savings'] as Map)['possible'] == true)
                Text('Or pay it all now from savings, keeping ${kes((result['pay_from_savings'] as Map)['savings_left_KES'] as num)}.'),
              Text(result['months_to_save_up_first'] is num
                  ? 'Or save up first: about ${result['months_to_save_up_first']} months from what you have left over.'
                  : 'Saving up first: ${result['months_to_save_up_first']}'),
            ]),
          _Box(title: 'Why', children: [
            ...((result['reasons'] as List?) ?? []).map((r) => Text('• $r')),
            if (result['before'] is Map && result['after'] is Map) ...[
              const SizedBox(height: 8),
              _BeforeAfter(before: (result['before'] as Map).cast<String, dynamic>(),
                  after: (result['after'] as Map).cast<String, dynamic>()),
            ],
          ]),
          if (result['cash_flow'] is List && (result['cash_flow'] as List).isNotEmpty)
            _Box(title: 'Month by month', children: [
              _CashFlow(rows: (result['cash_flow'] as List).map((r) => (r as Map).cast<String, dynamic>()).toList()),
            ]),
          if (cut is Map && cut['to_break_even'] != null) ...[
            _cutPlan(context, 'To stop being short each month', cut['to_break_even']),
            _cutPlan(context, 'To be comfortable', cut['to_be_comfortable']),
          ] else if (cut is Map && cut['monthly_cuts_KES'] != null)
            _Box(title: 'To make room for it', children: [
              ...(cut['monthly_cuts_KES'] as Map).cast<String, num>().entries
                  .map((e) => Text('• ${_cat(e.key)}: ${kes(e.value)} less a month')),
            ]),
          if (result['advice'] != null)
            _Box(title: 'What would work', children: [
              ...((result['advice'] as List).map((a) => Text('• $a'))),
            ]),
          if (result['id'] != null) _GoAhead(result: result),
          const SizedBox(height: 8),
          Text('Based on ${result['months_used'] ?? 'your recent'} month(s) of your own records. '
              'This is guidance from a model, not financial advice.', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            ...children,
          ]),
        ),
      );
}

/// "I'm doing this": records the decision so the budget, dashboard and later checks include it.
/// Checks stay "just exploring" until this is pressed.
class _GoAhead extends StatefulWidget {
  const _GoAhead({required this.result});
  final Map<String, dynamic> result;

  @override
  State<_GoAhead> createState() => _GoAheadState();
}

class _GoAheadState extends State<_GoAhead> {
  bool busy = false;
  List<String>? notes;

  @override
  void initState() {
    super.initState();
    final applied = widget.result['applied'];
    if (applied is Map) notes = ((applied['notes'] as List?) ?? []).cast<String>();
  }

  Future<void> _go() async {
    var how = 'instalments';
    final fromSavings = widget.result['pay_from_savings'];
    if (fromSavings is Map && fromSavings['possible'] == true) {
      final pick = await showDialog<String>(context: context, builder: (ctx) => SimpleDialog(
            title: const Text('How will you pay?'),
            children: [
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'instalments'),
                  child: Text('In instalments (${kes(widget.result['instalment_per_month_KES'] as num)} a month)')),
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'from_savings'),
                  child: const Text('All now, from my savings')),
            ],
          ));
      if (pick == null) return;
      how = pick;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final n = await context.read<AppState>().api.applyScenario(widget.result['id'] as int, how: how);
      if (mounted) setState(() => notes = n);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (notes != null) {
      return _Box(title: 'You are going ahead', children: [
        ...notes!.map((n) => Text('• $n')),
        const SizedBox(height: 4),
        Text('Your budget and dashboard now include this.', style: Theme.of(context).textTheme.bodySmall),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FilledButton.icon(
          onPressed: busy ? null : _go,
          icon: const Icon(Icons.check),
          label: const Text("I'm doing this"),
        ),
        const SizedBox(height: 4),
        Text('Until you press this, the check is just exploring: nothing in your budget changes.',
            style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
      ]),
    );
  }
}

/// What happens to the money each month while paying: left over, paused saving, savings balance.
class _CashFlow extends StatelessWidget {
  const _CashFlow({required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ...rows.take(12).map((r) {
        final parts = <String>['pay ${kes(r['pay_KES'] as num)}', '${kes(r['left_after_KES'] as num)} left'];
        if ((r['saving_paused_KES'] as num) > 0) parts.add('saving paused (${kes(r['saving_paused_KES'] as num)})');
        if ((r['from_savings_KES'] as num) > 0) parts.add('${kes(r['from_savings_KES'] as num)} from savings');
        final bal = r['savings_balance_KES'] as num;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: 'Month ${r['month']}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: '${parts.join(', ')}. Savings: '),
            TextSpan(text: kes(bal), style: TextStyle(color: bal < 0 ? Theme.of(context).colorScheme.error : null,
                fontWeight: FontWeight.w600)),
          ])),
        );
      }),
      if (rows.length > 12) Text('…and ${rows.length - 12} more month(s) like this.', style: small),
      if (rows.any((r) => (r['savings_balance_KES'] as num) < 0))
        Text('A negative balance means your savings run out before it is paid off.', style: small),
    ]);
  }
}

class _BeforeAfter extends StatelessWidget {
  const _BeforeAfter({required this.before, required this.after});
  final Map<String, dynamic> before, after;

  @override
  Widget build(BuildContext context) {
    TableRow row(String label, String key) => TableRow(children: [
          Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(label)),
          Text(kes(before[key] as num), textAlign: TextAlign.right),
          Text(kes(after[key] as num), textAlign: TextAlign.right),
        ]);
    return Table(columnWidths: const {0: FlexColumnWidth(2)}, children: [
      const TableRow(children: [Text(''), Text('Now', textAlign: TextAlign.right), Text('After', textAlign: TextAlign.right)]),
      row('Money in', 'income_KES'),
      row('Spending', 'spending_KES'),
      row('Left over', 'left_over_KES'),
    ]);
  }
}
