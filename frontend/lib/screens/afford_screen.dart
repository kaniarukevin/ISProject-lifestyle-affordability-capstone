import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/presets.dart';
import '../models/transaction.dart' show categoryLabel;
import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/format.dart';
import '../widgets/panel.dart';
import '../widgets/verdict.dart';
import 'why_score_sheet.dart';

/// The heart of the project: test a lifestyle change on your own numbers before committing to it.
/// Pick the kind of change, fill in a few numbers, Check. On a wide screen the answer appears beside the form;
/// on a phone it opens on its own page (design canvas, 6 Nov).
class AffordScreen extends StatefulWidget {
  const AffordScreen({super.key});

  static const sideBySideFrom = 900.0;

  @override
  State<AffordScreen> createState() => _AffordScreenState();
}

const _groups = {'Anyone': anyonePresets, 'Family': familyPresets, 'Students': studentPresets};

class _AffordScreenState extends State<AffordScreen> {
  List<Map<String, dynamic>> history = [];
  String _group = 'Anyone';
  Preset _preset = anyonePresets.first;
  Map<String, TextEditingController> _ctl = {};
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _result;      // shown beside the form on wide screens
  Map<String, dynamic>? _choice;

  @override
  void initState() {
    super.initState();
    final p = context.read<AppState>().profile;
    if (p != null && p.studying) {
      _group = 'Students';
    } else if (p != null && p.householdSize > 1) {
      _group = 'Family';
    }
    _select(_groups[_group]!.first);
    _loadHistory();
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _select(Preset p) {
    // The old fields are still on screen until the next frame: dispose their controllers after it.
    final old = _ctl.values.toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in old) {
        c.dispose();
      }
    });
    _preset = p;
    _ctl = {
      for (final f in p.fields) f.key: TextEditingController(text: f.initial == null ? '' : f.initial!.round().toString()),
    };
    _error = null;
    _result = null;
  }

  Future<void> _loadHistory() async {
    try {
      final h = await context.read<AppState>().api.scenarios();
      if (mounted) setState(() => history = h);
    } catch (_) {/* history is optional */}
  }

  Future<void> _check({required bool sideBySide}) async {
    final values = <String, num>{};
    for (final f in _preset.fields) {
      final v = num.tryParse(_ctl[f.key]!.text.replaceAll(',', '').trim());
      // isFinite and the cap stop "Infinity", "NaN" and 1e15 (audit A-15).
      if (v == null || !v.isFinite || v.abs() > 100000000 || (v < 0 && !f.allowNegative)) {
        setState(() => _error = 'Fill in "${f.label}" with a number.');
        return;
      }
      values[f.key] = v;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final choice = buildChoice(_preset, values);
      final r = await context.read<AppState>().api.afford(choice);
      if (!mounted) return;
      if (sideBySide) {
        setState(() {
          _result = r;
          _choice = choice;
        });
      } else {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen(result: r, choice: choice)));
      }
      _loadHistory();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPast(Map<String, dynamic> h) async {
    final r = (h['result'] as Map).cast<String, dynamic>();
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResultScreen(result: {...r, 'id': h['id']}, choice: (h['request'] as Map?)?.cast<String, dynamic>())));
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return LayoutBuilder(builder: (context, box) {
      final sideBySide = box.maxWidth >= AffordScreen.sideBySideFrom;
      final form = _form(theme, c, sideBySide);
      final past = _past(theme, c);
      return RefreshIndicator(
        onRefresh: _loadHistory,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Text('Try a change before you make it. Nothing is saved unless you go ahead.',
                style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [for (final g in _groups.keys) ButtonSegment(value: g, label: Text(g))],
                selected: {_group},
                onSelectionChanged: (s) => setState(() {
                  _group = s.first;
                  _select(_groups[_group]!.first);
                }),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in _groups[_group]!)
                ChoiceChip(
                  label: Text(p.title),
                  avatar: Icon(p.icon, size: 18, color: p == _preset ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
                  showCheckmark: false,
                  selected: p == _preset,
                  onSelected: (_) => setState(() => _select(p)),
                ),
            ]),
            const SizedBox(height: 20),
            if (sideBySide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(children: [form, if (past != null) ...[const SizedBox(height: 20), past]])),
                const SizedBox(width: 20),
                Expanded(
                  flex: 2,
                  child: _result == null
                      ? Panel(
                          child: Text('Your answer appears here: a verdict, your score before and after, what it does '
                              'to your budget month by month, and what would make it work.',
                              style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
                        )
                      : ResultView(result: _result!, choice: _choice, onChanged: _loadHistory,
                          onExploring: () => setState(() => _result = null)),
                ),
              ])
            else ...[
              form,
              if (past != null) ...[const SizedBox(height: 20), past],
            ],
          ],
        ),
      );
    });
  }

  Widget _form(ThemeData theme, AppColors c, bool sideBySide) => Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_preset.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(_preset.subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
          const SizedBox(height: 16),
          for (final f in _preset.fields) ...[
            TextField(
              key: ValueKey('${_preset.id}.${f.key}'),
              controller: _ctl[f.key],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: f.label, helperText: f.hint),
            ),
            const SizedBox(height: 14),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: c.warn)),
            ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : () => _check(sideBySide: sideBySide),
            child: _busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Check'),
          ),
        ]),
      );

  Widget? _past(ThemeData theme, AppColors c) {
    if (history.isEmpty) return null;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Past checks', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        for (final h in history.take(8))
          Builder(builder: (context) {
            final r = (h['result'] as Map).cast<String, dynamic>();
            final id = h['id'] as int;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text((r['title'] ?? 'Check') as String),
              subtitle: r['applied'] != null ? const Text('Going ahead') : null,
              onTap: () => _openPast(h),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (r['verdict'] is String) VerdictChip(r['verdict'] as String),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: 'Delete this check',
                  onPressed: () async {
                    final sure = await showChoiceSheet<bool>(context,
                        title: 'Delete this check?',
                        message: 'It only removes the check from this list. Nothing else changes.',
                        choices: const [SheetChoice('Delete', true, primary: true)]);
                    if (sure != true || !context.mounted) return;
                    await context.read<AppState>().api.deleteScenario(id);
                    _loadHistory();
                  },
                ),
              ]),
            );
          }),
      ]),
    );
  }
}

/// The answer on its own page (phones, and past checks).
class ResultScreen extends StatelessWidget {
  const ResultScreen({super.key, required this.result, this.choice});
  final Map<String, dynamic> result;
  final Map<String, dynamic>? choice;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text((result['title'] ?? 'Your answer') as String)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [ResultView(result: result, choice: choice, onExploring: () => Navigator.of(context).pop())],
          ),
        ),
      );
}

/// The answer, in the order a person needs it: verdict and score, month by month, the budget before and after,
/// why, what would make it work, then "I'm doing this" or "Just exploring".
class ResultView extends StatelessWidget {
  const ResultView({super.key, required this.result, this.choice, this.onChanged, this.onExploring});
  final Map<String, dynamic> result;
  final Map<String, dynamic>? choice;
  final VoidCallback? onChanged;
  final VoidCallback? onExploring;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final verdict = (result['verdict'] ?? '') as String;
    final before = result['score_before'] as num?;
    final after = result['score_after'] as num?;
    final reasons = ((result['reasons'] as List?) ?? []).cast<String>();
    final phases = ((result['phases'] as List?) ?? []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final cash = ((result['cash_flow'] as List?) ?? []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final budgets = (result['budgets'] as Map?)?.cast<String, dynamic>();
    final lines = ((budgets?['lines'] as List?) ?? []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final cutText = _cutText(result['what_to_cut']);
    final advice = ((result['advice'] as List?) ?? []).cast<String>();
    const gap = SizedBox(height: 20);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          VerdictChip(verdict, large: true),
          const SizedBox(height: 12),
          if (reasons.isNotEmpty) Text(reasons.first, style: theme.textTheme.bodyLarge),
          if (before != null && after != null) ...[
            const SizedBox(height: 18),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              _Num(label: 'Score now', value: '$before'),
              const Padding(padding: EdgeInsets.fromLTRB(14, 0, 14, 12), child: Icon(Icons.arrow_forward_rounded)),
              _Num(label: phases.length > 1 ? 'While paying' : 'After', value: '$after',
                  color: after < before ? c.warn : null),
            ]),
            const SizedBox(height: 14),
            ScoreScale(score: after, before: before),
            if ((result['track_record'] as Map?)?['lowered_verdict'] == true) ...[
              const SizedBox(height: 10),
              Text('Lowered from Affordable because of your track record over the year.',
                  style: theme.textTheme.bodySmall?.copyWith(color: c.warn)),
            ],
            if (result['score_note'] != null) ...[
              const SizedBox(height: 6),
              Text(result['score_note'] as String, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            ],
            if (choice != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => showWhyScore(context, choice: choice), child: const Text('Why this score?')),
              ),
          ],
        ]),
      ),
      if (phases.length > 1 || cash.isNotEmpty) ...[
        gap,
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Month by month', style: theme.textTheme.titleLarge),
            const SizedBox(height: 14),
            if (phases.length > 1)
              for (final p in phases)
                _Phase(
                  color: verdictColors(context, (p['verdict'] ?? '') as String).$1,
                  title: '${p['label']}${p['lasts'] != null ? ' · ${p['lasts']}' : ''}',
                  text: '${p['verdict']} · score ${p['score_after']} · '
                      '${(p['left_over_KES'] as num) < 0 ? 'KES ${money(-(p['left_over_KES'] as num))} short a month' : 'KES ${money(p['left_over_KES'] as num)} left a month'}',
                )
            else
              for (final r in cash.take(6))
                _Phase(
                  color: (r['savings_balance_KES'] as num) < 0 ? c.critical : c.range,
                  title: 'Month ${r['month']}',
                  text: 'KES ${money(r['left_after_KES'] as num)} left'
                      '${(r['from_savings_KES'] as num) > 0 ? ', KES ${money(r['from_savings_KES'] as num)} from savings' : ''}'
                      ' · savings ${money(r['savings_balance_KES'] as num)}',
                ),
            if (phases.length <= 1 && cash.length > 6)
              Text('…and ${cash.length - 6} more month(s) like this.', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
          ]),
        ),
      ],
      if (lines.isNotEmpty) ...[
        gap,
        Panel(child: _BudgetTable(lines: lines, note: budgets?['note'] as String?)),
      ] else if (result['before'] is Map && result['after'] is Map) ...[
        gap,
        Panel(child: _MoneyTable(before: (result['before'] as Map).cast<String, dynamic>(),
            after: (result['after'] as Map).cast<String, dynamic>())),
      ],
      if (result['instalment_per_month_KES'] != null) ...[
        gap,
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ways to pay', style: theme.textTheme.titleLarge),
            const SizedBox(height: 10),
            Text('In instalments: ${kesAmount(result['instalment_per_month_KES'] as num)} a month'
                '${result['instalment_months'] != null ? ' for ${result['instalment_months']} months' : result['lasts_months'] != null ? ' for ${result['lasts_months']} months' : ''}'
                '${result['total_paid_KES'] != null ? ', ${kesAmount(result['total_paid_KES'] as num)} in total' : ''}.',
                style: theme.textTheme.bodyLarge),
            if (result['pay_from_savings'] is Map && (result['pay_from_savings'] as Map)['possible'] == true)
              Text('Or all now from savings, keeping ${kesAmount((result['pay_from_savings'] as Map)['savings_left_KES'] as num)}.',
                  style: theme.textTheme.bodyLarge),
            if (result['months_to_save_up_first'] is num)
              Text('Or save up first: about ${result['months_to_save_up_first']} months.', style: theme.textTheme.bodyLarge),
          ]),
        ),
      ],
      if (reasons.length > 1) ...[
        gap,
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Why', style: theme.textTheme.titleLarge),
            const SizedBox(height: 10),
            for (final r in reasons.skip(1))
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(r, style: theme.textTheme.bodyMedium)),
          ]),
        ),
      ],
      if (cutText != null || advice.isNotEmpty) ...[
        gap,
        Panel(
          color: const Color(0xFF111111),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(verdict == 'Affordable' ? 'To make room for it' : 'What would make it work',
                style: theme.textTheme.titleLarge?.copyWith(color: Colors.white)),
            const SizedBox(height: 10),
            if (cutText != null)
              Text(cutText, style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFFE4E4DE))),
            for (final a in advice)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(a, style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFFE4E4DE))),
              ),
          ]),
        ),
      ],
      if (result['id'] != null) ...[
        gap,
        _GoAhead(result: result, onChanged: onChanged, onExploring: onExploring),
      ],
      const SizedBox(height: 12),
      Text('Based on ${result['months_used'] ?? 'your recent'} month(s) of your own records. '
          'This is guidance from a model, not financial advice.',
          style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
    ]);
  }

  /// what_to_cut in words: the plan to stop being short (or to be comfortable), or the cuts that make room.
  static String? _cutText(dynamic cut) {
    if (cut is! Map) return null;
    String plan(dynamic p) {
      if (p is String) return p;
      final m = (p as Map).cast<String, dynamic>();
      final cuts = (m['monthly_cuts_KES'] as Map).cast<String, num>().entries.where((e) => e.value > 0);
      return 'Spend ${cuts.map((e) => 'KES ${money(e.value)} less on ${categoryLabel(e.key).toLowerCase()}').join(', ')} '
          'a month. That frees ${kesAmount(m['total_cut_KES'] as num)} and leaves ${kesAmount(m['left_over_after_KES'] as num)}.';
    }

    if (cut['to_be_comfortable'] != null) return plan(cut['to_be_comfortable']);
    if (cut['to_break_even'] != null) return plan(cut['to_break_even']);
    if (cut['monthly_cuts_KES'] is Map) {
      final cuts = (cut['monthly_cuts_KES'] as Map).cast<String, num>().entries.where((e) => e.value > 0);
      return 'Spend ${cuts.map((e) => 'KES ${money(e.value)} less on ${categoryLabel(e.key).toLowerCase()}').join(', ')} a month.';
    }
    return null;
  }
}

class _Num extends StatelessWidget {
  const _Num({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).muted)),
      Text(value, style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, color: color)),
    ]);
  }
}

class _Phase extends StatelessWidget {
  const _Phase({required this.color, required this.title, required this.text});
  final Color color;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
              Text(text, style: theme.textTheme.bodyMedium),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The recommended budget now and with the change, side by side; changed lines first and marked.
class _BudgetTable extends StatelessWidget {
  const _BudgetTable({required this.lines, this.note});
  final List<Map<String, dynamic>> lines;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    bool changed(Map<String, dynamic> l) => l['after'] != null && l['after'] != l['now'];
    final sorted = [...lines.where(changed), ...lines.where((l) => !changed(l))];
    final shown = sorted.take(8).toList();
    final hidden = sorted.length - shown.length;
    Widget cell(String s, {bool head = false, Color? color, bool bold = false}) => Text(s,
        textAlign: TextAlign.right,
        style: (head ? theme.textTheme.bodySmall?.copyWith(color: c.muted) : theme.textTheme.bodyMedium)
            ?.copyWith(color: color, fontWeight: bold ? FontWeight.w700 : null));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Your budget, before and after', style: theme.textTheme.titleLarge),
      const SizedBox(height: 10),
      Table(
        columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1)},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            Text('Each month', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            cell('Now', head: true),
            cell('After', head: true),
          ]),
          for (final l in shown)
            TableRow(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant))),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(categoryLabel(l['category'] as String),
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ),
                cell(money(l['now'] as num)),
                cell(l['after'] == null ? '—' : money(l['after'] as num),
                    color: changed(l) && (l['after'] as num) < (l['now'] as num) ? c.warn : null, bold: changed(l)),
              ],
            ),
        ],
      ),
      if (hidden > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('$hidden more line(s) stay the same.', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        ),
      if (note != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(note!, style: theme.textTheme.bodySmall?.copyWith(color: c.warn))),
    ]);
  }
}

class _MoneyTable extends StatelessWidget {
  const _MoneyTable({required this.before, required this.after});
  final Map<String, dynamic> before, after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).muted);
    TableRow row(String label, String key) => TableRow(children: [
          Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(label)),
          Text(money(before[key] as num), textAlign: TextAlign.right),
          Text(money(after[key] as num), textAlign: TextAlign.right),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Each month, before and after', style: theme.textTheme.titleLarge),
      const SizedBox(height: 10),
      Table(columnWidths: const {0: FlexColumnWidth(2)}, children: [
        TableRow(children: [const SizedBox(), Text('Now', textAlign: TextAlign.right, style: muted),
          Text('After', textAlign: TextAlign.right, style: muted)]),
        row('Money in', 'income_KES'),
        row('Spending', 'spending_KES'),
        row('Left over', 'left_over_KES'),
      ]),
    ]);
  }
}

/// "I'm doing this": records the decision so the budget, overview and later checks include it, after a confirm
/// sheet. Until then the check is just exploring.
class _GoAhead extends StatefulWidget {
  const _GoAhead({required this.result, this.onChanged, this.onExploring});
  final Map<String, dynamic> result;
  final VoidCallback? onChanged;
  final VoidCallback? onExploring;

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
    final fromSavings = widget.result['pay_from_savings'];
    final canPayNow = fromSavings is Map && fromSavings['possible'] == true;
    final how = await showChoiceSheet<String>(
      context,
      title: 'Go ahead with this?',
      message: 'Tosha adds it to your plans and updates your budget. You can remove it later in Plans.',
      choices: [
        if (canPayNow && widget.result['instalment_per_month_KES'] != null) ...[
          SheetChoice('Yes, in instalments (${kesAmount(widget.result['instalment_per_month_KES'] as num)} a month)',
              'instalments', primary: true),
          const SheetChoice('Yes, all now from my savings', 'from_savings'),
        ] else
          const SheetChoice("Yes, I'm doing this", 'instalments', primary: true),
      ],
    );
    if (how == null || !mounted) return;
    setState(() => busy = true);
    try {
      final n = await context.read<AppState>().api.applyScenario(widget.result['id'] as int, how: how);
      if (mounted) setState(() => notes = n);
      widget.onChanged?.call();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    if (notes != null) {
      return Panel(
        color: c.lime,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("You're going ahead", style: theme.textTheme.titleLarge?.copyWith(color: const Color(0xFF111111))),
          const SizedBox(height: 8),
          for (final n in notes!) Text(n, style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF111111))),
          const SizedBox(height: 6),
          Text('Your budget and overview now include this.',
              style: theme.textTheme.bodySmall?.copyWith(color: const Color(0xFF2B3110))),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
        onPressed: busy ? null : _go,
        child: const Text("I'm doing this"),
      ),
      const SizedBox(height: 10),
      if (widget.onExploring != null)
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: widget.onExploring,
          child: const Text('Just exploring'),
        ),
      const SizedBox(height: 6),
      Text('Until you press "I\'m doing this", nothing in your budget changes.',
          textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
    ]);
  }
}
