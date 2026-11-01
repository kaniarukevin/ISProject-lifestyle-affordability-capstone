import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/presets.dart';
import '../models/transaction.dart' show spendingCategories;
import '../services/api.dart';
import '../state/app_state.dart';
import 'profile_screen.dart' show kes;

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
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _VerdictDot(verdict: r['verdict'] as String? ?? ''),
                title: Text((r['title'] ?? 'Check') as String),
                subtitle: Text('${r['verdict']}${r['score_after'] != null ? ' · score ${r['score_after']}' : ''}'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ResultScreen(result: r))),
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
      final r = await context.read<AppState>().api.afford(buildChoice(widget.preset, values));
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen(result: r)));
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
  const ResultScreen({super.key, required this.result});
  final Map<String, dynamic> result;

  String _cat(String k) => spendingCategories[k] ?? k;

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
                  Text('Affordability score: $before → $after out of 100'),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: after / 100, minHeight: 10, color: color,
                        backgroundColor: color.withValues(alpha: 0.15)),
                  ),
                ],
              ]),
            ),
          ),
          if (result['instalment_per_month_KES'] != null)
            _Box(title: 'Two ways to pay', children: [
              Text('In instalments: ${kes(result['instalment_per_month_KES'] as num)} a month.'),
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
