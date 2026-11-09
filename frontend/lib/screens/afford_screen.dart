import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/presets.dart';
import '../models/profile.dart';
import '../models/transaction.dart' show categoryLabel;
import '../services/api.dart';
import '../state/app_state.dart';
import '../state/reload_on_change.dart';
import '../theme/app_theme.dart';
import '../widgets/busy_words.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/format.dart';
import '../widgets/panel.dart';
import '../widgets/rating_row.dart';
import '../widgets/verdict.dart';
import 'why_score_sheet.dart';

/// The heart of the project: test a lifestyle change on your own numbers before committing to it.
/// 1. "What are you thinking of?": picture cards, the first row suggested from the profile. 2. A short form:
/// on a phone its own page with Check fixed at the bottom; on a wide screen beside the answer. 3. The answer.
class AffordScreen extends StatefulWidget {
  const AffordScreen({super.key});

  static const sideBySideFrom = 900.0;

  @override
  State<AffordScreen> createState() => _AffordScreenState();
}

/// The four changes most likely to matter to this person, from what they told us at setup.
List<Preset> suggestedPresets(Profile? p) {
  Preset find(String id) => [...anyonePresets, ...familyPresets, ...studentPresets].firstWhere((x) => x.id == id);
  if (p != null && p.studying) return [find('laptop'), find('offcampus'), find('trip'), find('helb')];
  if (p != null && (p.householdSize > 1 || p.childrenInSchool > 0)) {
    return [find('move'), find('school'), find('baby'), find('buy')];
  }
  return [find('buy'), find('loan'), find('save'), find('move')];
}

class _AffordScreenState extends State<AffordScreen> with ReloadOnChange {
  @override
  Future<void> reloadQuietly() => _loadHistory();

  List<Map<String, dynamic>> history = [];
  Preset? _preset;                    // the change being looked at (wide screens keep it open beside the answer)
  Map<String, dynamic>? _result;
  Map<String, dynamic>? _choice;

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

  Future<void> _pick(Preset p, bool sideBySide) async {
    if (sideBySide) {
      setState(() {
        _preset = p;
        _result = null;
      });
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _AskPage(preset: p)));
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final suggested = suggestedPresets(context.watch<AppState>().profile);
    final more = [
      for (final p in [...anyonePresets, ...familyPresets, ...studentPresets])
        if (!suggested.contains(p)) p,
    ];
    return LayoutBuilder(builder: (context, box) {
      final sideBySide = box.maxWidth >= AffordScreen.sideBySideFrom;
      final pastLink = history.isEmpty
          ? null
          : TextButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PastChecksScreen(history: history)));
                _loadHistory();
              },
              icon: const Icon(Icons.history_rounded),
              label: Text('Past checks (${history.length})'),
            );

      if (sideBySide && _preset != null) {
        return ListView(padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _preset = null;
                      _result = null;
                    }),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('Choose something else'),
                  ),
                  const Spacer(),
                  ?pastLink,
                ]),
                const SizedBox(height: 8),
                Panel(
                  child: AskForm(
                    key: ValueKey(_preset!.id),
                    preset: _preset!,
                    onResult: (r, choice) {
                      setState(() {
                        _result = r;
                        _choice = choice;
                      });
                      _loadHistory();
                    },
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 20),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.only(top: 56),
                child: _result == null
                    ? Panel(
                        child: Text('Your answer appears here: a verdict, your score before and after, what it does '
                            'to your budget month by month, and what would make it work.',
                            style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
                      )
                    : ResultView(result: _result!, choice: _choice, onChanged: _loadHistory,
                        onExploring: () => setState(() => _result = null)),
              ),
            ),
          ]),
        ]);
      }

      final cols = sideBySide ? 4 : (box.maxWidth >= 600 ? 3 : 2);
      Widget grid(List<Preset> ps) => LayoutBuilder(builder: (context, b) {
            const gap = 12.0;
            final w = (b.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(spacing: gap, runSpacing: gap, children: [
              // Every card the same height, so rows line up whatever the title length (9 Nov: ragged rows).
              for (final p in ps)
                SizedBox(width: w, height: MediaQuery.textScalerOf(context).scale(176), child: _PresetCard(preset: p, onTap: () => _pick(p, sideBySide))),
            ]);
          });
      return RefreshIndicator(
        onRefresh: _loadHistory,
        child: ListView(padding: EdgeInsets.only(bottom: 40 + MediaQuery.paddingOf(context).bottom), children: [
          // On a phone the line gets the full width and Past checks sits under it, instead of squeezing both.
          if (box.maxWidth >= 600)
            Row(children: [
              Expanded(
                child: Text('Try a change before you make it. Nothing is saved unless you go ahead.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
              ),
              ?pastLink,
            ])
          else ...[
            Text('Try a change before you make it. Nothing is saved unless you go ahead.',
                style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
            if (pastLink != null) Align(alignment: Alignment.centerLeft, child: pastLink),
          ],
          const SizedBox(height: 20),
          Text('Suggested for you', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          grid(suggested),
          const SizedBox(height: 28),
          Text('More ideas', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          grid(more),
        ]),
      );
    });
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.preset, required this.onTap});
  final Preset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(radius: 20, backgroundColor: c.field, child: Icon(preset.icon, size: 20, color: theme.colorScheme.onSurface)),
            const Spacer(),
            Text(preset.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(preset.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
          ]),
        ),
      ),
    );
  }
}

/// The few numbers a change needs, and Check. [sticky]: Check is fixed at the bottom (phone page).
class AskForm extends StatefulWidget {
  const AskForm({super.key, required this.preset, required this.onResult, this.sticky = false});
  final Preset preset;
  final void Function(Map<String, dynamic> result, Map<String, dynamic> choice) onResult;
  final bool sticky;

  @override
  State<AskForm> createState() => _AskFormState();
}

class _AskFormState extends State<AskForm> {
  late final Map<String, TextEditingController> _ctl = {
    for (final f in widget.preset.fields)
      f.key: TextEditingController(text: f.initial == null ? '' : f.initial!.round().toString()),
  };
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _check() async {
    final values = <String, num>{};
    for (final f in widget.preset.fields) {
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
      final choice = buildChoice(widget.preset, values);
      final r = await context.read<AppState>().api.afford(choice);
      if (mounted) widget.onResult(r, choice);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final fields = <Widget>[
      Text(widget.preset.title, style: theme.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(widget.preset.subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
      const SizedBox(height: 18),
      for (final f in widget.preset.fields) ...[
        TextField(
          controller: _ctl[f.key],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: f.label, helperText: f.hint),
          onSubmitted: (_) => _check(),
        ),
        const SizedBox(height: 14),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: TextStyle(color: c.warn))),
    ];
    final button = FilledButton(
      style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54), backgroundColor: c.lime, foregroundColor: c.onLime),
      onPressed: _busy ? null : _check,
      child: _busy ? const BusyWords(lines: checkingWords) : const Text('Check'),
    );
    if (!widget.sticky) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...fields, button]);
    }
    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), children: fields)),
      SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), child: button)),
    ]);
  }
}

/// Phones: the form on its own page, Check always visible at the bottom; the answer opens on the next page.
class _AskPage extends StatelessWidget {
  const _AskPage({required this.preset});
  final Preset preset;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Can I afford it?')),
        body: AskForm(
          preset: preset,
          sticky: true,
          onResult: (r, choice) => Navigator.of(context)
              .pushReplacement(MaterialPageRoute(builder: (_) => ResultScreen(result: r, choice: choice))),
        ),
      );
}

/// Every check so far: open one to see the answer again, or delete it.
class PastChecksScreen extends StatefulWidget {
  const PastChecksScreen({super.key, required this.history});
  final List<Map<String, dynamic>> history;

  @override
  State<PastChecksScreen> createState() => _PastChecksScreenState();
}

class _PastChecksScreenState extends State<PastChecksScreen> {
  late final List<Map<String, dynamic>> items = [...widget.history];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Past checks')),
        body: PageWidth(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
            for (final h in items)
              Builder(builder: (context) {
                final r = (h['result'] as Map).cast<String, dynamic>();
                return Card(
                  child: ListTile(
                    title: Text((r['title'] ?? 'Check') as String),
                    subtitle: Text('${(h['created_at'] as String? ?? '').split('T').first}'
                        '${r['applied'] != null ? ' · going ahead' : ''}'),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ResultScreen(result: {...r, 'id': h['id']},
                            choice: (h['request'] as Map?)?.cast<String, dynamic>()))),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (r['verdict'] is String) VerdictChip(r['verdict'] as String),
                      IconButton(
                        tooltip: 'Delete this check',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () async {
                          final sure = await showChoiceSheet<bool>(context,
                              title: 'Delete this check?',
                              message: 'It only removes the check from this list. Nothing else changes.',
                              choices: const [SheetChoice('Delete', true, primary: true)]);
                          if (sure != true || !context.mounted) return;
                          await context.read<AppState>().api.deleteScenario(h['id'] as int);
                          setState(() => items.remove(h));
                        },
                      ),
                    ]),
                  ),
                );
              }),
          ]),
        ),
      );
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
        gap,
        RatingCard(
            key: ValueKey('rate-${result['id']}'),
            where: 'afford',
            scenarioId: result['id'] as int,
            question: 'Does this answer match what you would expect?'),
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
        style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(54), backgroundColor: c.lime, foregroundColor: c.onLime),
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
