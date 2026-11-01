import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/commitments.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import 'profile_screen.dart' show kes;

/// Step 2 of the journey: rent, fees, debts and goals, turned into monthly figures by the /commitments engine.
class CommitmentsScreen extends StatefulWidget {
  const CommitmentsScreen({super.key});

  @override
  State<CommitmentsScreen> createState() => _CommitmentsScreenState();
}

class _CommitmentsScreenState extends State<CommitmentsScreen> {
  Commitments? c;
  Map<String, dynamic>? summary;
  bool busy = false;
  String? error;

  Api get api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await api.getCommitments();
      setState(() => c = Commitments.fromJson(data));
      if (c!.obligations.isNotEmpty || c!.debts.isNotEmpty || c!.goals.isNotEmpty) await _save(quiet: true);
    } on ApiException catch (e) {
      setState(() {
        c = Commitments();
        error = e.message;
      });
    }
  }

  Future<void> _save({bool quiet = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final s = await api.putCommitments(c!.toJson());
      setState(() => summary = s);
      if (!quiet && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
      }
    } on ApiException catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _add(String kind) async {
    final item = await showDialog<Object>(context: context, builder: (_) => _AddDialog(kind: kind));
    if (item == null) return;
    setState(() {
      if (item is Obligation) c!.obligations.add(item);
      if (item is Debt) c!.debts.add(item);
      if (item is Goal) c!.goals.add(item);
    });
    await _save();
  }

  void _remove(VoidCallback removal) {
    setState(removal);
    _save(quiet: true);
  }

  @override
  Widget build(BuildContext context) {
    if (c == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final s = summary;
    final fixed = (s?['for_budget']?['fixed'] as Map?)?.cast<String, dynamic>() ?? {};
    final monthlyTotal = fixed.values.fold<num>(0, (a, v) => a + (v as num));
    final debts = s?['debts'] as Map<String, dynamic>?;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Your commitments', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('What you must pay and what you are saving for. Everything is turned into a monthly amount '
            'so your budget can set it aside.', style: theme.textTheme.bodySmall),
        if (error != null) Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
        if (s != null) Card(
          margin: const EdgeInsets.symmetric(vertical: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Committed every month', style: theme.textTheme.titleSmall),
              Text(kes(monthlyTotal), style: theme.textTheme.headlineMedium),
              if ((s['for_budget']?['goal_per_month'] ?? 0) > 0)
                Text('Plus ${kes(s['for_budget']['goal_per_month'] as num)} a month towards your goals'),
              if (debts != null) ...[
                const Divider(),
                Text(debts['as_planned']['debt_free_by'] != null
                    ? 'Debt-free by ${debts['as_planned']['debt_free_by']}, paying '
                        '${kes(debts['as_planned']['total_interest_KES'] as num)} in interest'
                    : 'At these payments some debts will never be cleared.'),
                if (debts['extra_saves'] != null)
                  Text('Paying ${kes(c!.extraPerMonth)} extra a month saves '
                      '${debts['extra_saves']['months']} months and ${kes(debts['extra_saves']['interest_KES'] as num)}.',
                      style: TextStyle(color: theme.colorScheme.primary)),
              ],
              ...((s['warnings'] as List?) ?? []).map((w) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('⚠ $w', style: TextStyle(color: theme.colorScheme.error)),
                  )),
            ]),
          ),
        ),
        _Section(
          title: 'Bills and obligations',
          empty: 'Rent, school fees, chama, insurance…',
          onAdd: () => _add('obligation'),
          children: c!.obligations.asMap().entries.map((e) => _Row(
                title: e.value.name,
                subtitle: '${kes(e.value.amount)} ${obligationFrequencies[e.value.frequency]} · '
                    '${obligationCategories[e.value.category]}',
                onDelete: () => _remove(() => c!.obligations.removeAt(e.key)),
              )).toList(),
        ),
        _Section(
          title: 'Debts',
          empty: 'Fuliza, M-Shwari, SACCO or bank loan, phone on credit…',
          onAdd: () => _add('debt'),
          children: [
            ...c!.debts.asMap().entries.map((e) {
              final plan = (debts?['as_planned']?['debts'] as List?)?.elementAtOrNull(e.key) as Map?;
              return _Row(
                title: e.value.name,
                subtitle: '${kes(e.value.balance)} owed · ${e.value.annualRate}% a year · '
                    '${kes(e.value.monthlyPayment)} a month'
                    '${plan != null && plan['cleared_by'] != null ? ' · cleared by ${plan['cleared_by']}' : ''}',
                onDelete: () => _remove(() => c!.debts.removeAt(e.key)),
              );
            }),
            if (c!.debts.isNotEmpty)
              Row(children: [
                const Expanded(child: Text('What if I pay extra each month?')),
                SizedBox(
                  width: 110,
                  child: TextFormField(
                    initialValue: c!.extraPerMonth == 0 ? '' : c!.extraPerMonth.round().toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(prefixText: 'KES '),
                    onFieldSubmitted: (v) {
                      c!.extraPerMonth = double.tryParse(v.replaceAll(',', '')) ?? 0;
                      _save(quiet: true);
                    },
                  ),
                ),
              ]),
          ],
        ),
        _Section(
          title: 'Savings goals',
          empty: 'A new phone, an emergency fund, a trip…',
          onAdd: () => _add('goal'),
          children: c!.goals.asMap().entries.map((e) {
            final g = (s?['goals'] as List?)?.elementAtOrNull(e.key) as Map?;
            return _Row(
              title: e.value.name,
              subtitle: '${kes(e.value.target)} in ${e.value.monthsLeft} months'
                  '${g != null ? ' · save ${kes(g['monthly_needed_KES'] as num)} a month' : ''}',
              onDelete: () => _remove(() => c!.goals.removeAt(e.key)),
            );
          }).toList(),
        ),
        if (busy) const LinearProgressIndicator(),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.empty, required this.onAdd, required this.children});
  final String title, empty;
  final VoidCallback onAdd;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add')),
          ]),
          if (children.isEmpty) Text(empty, style: Theme.of(context).textTheme.bodySmall),
          ...children,
        ]),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.subtitle, required this.onDelete});
  final String title, subtitle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete),
      );
}

/// One dialog for all three kinds, so the fields stay consistent.
class _AddDialog extends StatefulWidget {
  const _AddDialog({required this.kind});
  final String kind; // obligation, debt, goal

  @override
  State<_AddDialog> createState() => _AddDialogState();
}

class _AddDialogState extends State<_AddDialog> {
  final name = TextEditingController();
  final a = TextEditingController(); // amount / balance / target
  final b = TextEditingController(); // rate / saved
  final d = TextEditingController(); // monthly payment / months left
  String frequency = 'monthly', category = 'housing';
  String? error;

  @override
  void dispose() {
    for (final t in [name, a, b, d]) {
      t.dispose();
    }
    super.dispose();
  }

  double? _n(TextEditingController t) => double.tryParse(t.text.replaceAll(',', '').trim());

  void _submit() {
    final n = name.text.trim();
    Object? item;
    if (widget.kind == 'obligation' && n.isNotEmpty && (_n(a) ?? 0) > 0) {
      item = Obligation(name: n, amount: _n(a)!, frequency: frequency, category: category);
    } else if (widget.kind == 'debt' && n.isNotEmpty && (_n(a) ?? 0) > 0 && (_n(d) ?? 0) > 0) {
      item = Debt(name: n, balance: _n(a)!, annualRate: _n(b) ?? 0, monthlyPayment: _n(d)!);
    } else if (widget.kind == 'goal' && n.isNotEmpty && (_n(a) ?? 0) > 0 && (_n(d) ?? 0) >= 1) {
      item = Goal(name: n, target: _n(a)!, saved: _n(b) ?? 0, monthsLeft: _n(d)!.round());
    }
    if (item == null) {
      setState(() => error = 'Fill in the name and the amounts.');
      return;
    }
    Navigator.of(context).pop(item);
  }

  Widget _field(TextEditingController t, String label, {String? hint, bool number = true}) => TextField(
        controller: t,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(labelText: label, helperText: hint),
      );

  @override
  Widget build(BuildContext context) {
    final k = widget.kind;
    return AlertDialog(
      title: Text(k == 'obligation' ? 'Add a bill or obligation' : k == 'debt' ? 'Add a debt' : 'Add a savings goal'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _field(name, 'Name', number: false,
              hint: k == 'obligation' ? 'e.g. Rent, School fees, Chama' : k == 'debt' ? 'e.g. Fuliza, SACCO loan' : 'e.g. New phone'),
          if (k == 'obligation') ...[
            _field(a, 'Amount (KES)'),
            DropdownButtonFormField<String>(
              initialValue: frequency,
              decoration: const InputDecoration(labelText: 'How often'),
              items: obligationFrequencies.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setState(() => frequency = v!),
            ),
            DropdownButtonFormField<String>(
              initialValue: category,
              decoration: const InputDecoration(labelText: 'Type'),
              items: obligationCategories.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setState(() => category = v!),
            ),
          ],
          if (k == 'debt') ...[
            _field(a, 'Amount still owed (KES)'),
            _field(b, 'Interest rate per year (%)', hint: 'Leave empty if there is no interest'),
            _field(d, 'Monthly payment (KES)'),
          ],
          if (k == 'goal') ...[
            _field(a, 'Target amount (KES)'),
            _field(b, 'Already saved (KES)'),
            _field(d, 'Months until you need it'),
          ],
          if (error != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}
