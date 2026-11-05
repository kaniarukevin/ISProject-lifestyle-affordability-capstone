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
      // Goals saved before deadlines existed get one now, so they start counting down.
      for (final g in c!.goals) {
        if (g.deadline == null && !g.done) g.deadline = Goal.deadlineIn(g.monthsLeft);
      }
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

  /// Change an item: the same form, filled in. Saved as soon as it is confirmed.
  Future<void> _edit(String kind, Object current, void Function(Object) replace) async {
    final item = await showDialog<Object>(context: context, builder: (_) => _AddDialog(kind: kind, initial: current));
    if (item == null) return;
    setState(() => replace(item));
    await _save();
  }

  Future<void> _markPaid(int index) async {
    setState(() => busy = true);
    try {
      final s = await api.markPaid(index);
      final data = await api.getCommitments();
      if (!mounted) return;
      setState(() {
        summary = s;
        c = Commitments.fromJson(data);
      });
      final next = c!.obligations[index].nextDue;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Marked paid.${next != null ? ' Next due ${_day(next)}.' : ''}')));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
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
          children: c!.obligations.asMap().entries.map((e) {
            final row = (s?['obligations'] as List?)?.elementAtOrNull(e.key) as Map?;
            final status = row?['status'] as String?;
            final days = row?['due_in_days'] as int?;
            final dueText = e.value.nextDue == null
                ? ''
                : status == 'overdue'
                    ? ' · overdue since ${_day(e.value.nextDue!)}'
                    : status == 'due_soon'
                        ? ' · due ${days == 0 ? 'today' : 'in $days day(s)'}'
                        : ' · next due ${_day(e.value.nextDue!)}';
            return _Row(
              title: e.value.name,
              subtitle: '${kes(e.value.amount)} ${obligationFrequencies[e.value.frequency]} · '
                  '${obligationCategories[e.value.category]}$dueText',
              subtitleColor: status == 'overdue' ? theme.colorScheme.error : null,
              onDelete: () => _remove(() => c!.obligations.removeAt(e.key)),
              onTap: () => _edit('obligation', e.value, (x) => c!.obligations[e.key] = x as Obligation),
              extra: e.value.nextDue == null
                  ? null
                  : IconButton(tooltip: 'Mark paid', icon: const Icon(Icons.check_circle_outline),
                      onPressed: busy ? null : () => _markPaid(e.key)),
            );
          }).toList(),
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
                onTap: () => _edit('debt', e.value, (x) => c!.debts[e.key] = x as Debt),
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
            // Matched by name: the server's list leaves reached goals out, so positions differ.
            final g = ((s?['goals'] as List?) ?? []).cast<Map>().where((x) => x['name'] == e.value.name).firstOrNull;
            if (e.value.done) {
              // Reached: shown, nothing more is set aside for it, nothing to edit.
              return _Row(
                title: '✓ ${e.value.name}',
                subtitle: 'Reached${e.value.doneOn != null ? ' on ${e.value.doneOn}' : ''} · ${kes(e.value.target)}',
                onDelete: () => _remove(() => c!.goals.removeAt(e.key)),
              );
            }
            return _Row(
              title: e.value.name,
              subtitle: '${kes(e.value.target)} in ${e.value.monthsLeft} months'
                  '${g != null ? ' · save ${kes(g['monthly_needed_KES'] as num)} a month' : ''}',
              onDelete: () => _remove(() => c!.goals.removeAt(e.key)),
              onTap: () => _edit('goal', e.value, (x) => c!.goals[e.key] = x as Goal),
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
  const _Row({required this.title, required this.subtitle, required this.onDelete, this.onTap, this.extra,
      this.subtitleColor});
  final String title, subtitle;
  final VoidCallback onDelete;
  final VoidCallback? onTap;      // change it
  final Widget? extra;            // e.g. "Mark paid"
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: onTap,
        title: Text(title),
        subtitle: Text(subtitle, style: subtitleColor == null ? null : TextStyle(color: subtitleColor)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          ?extra,
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete),
        ]),
      );
}

const _monthShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// '2026-12-05' -> '5 Dec 2026'.
String _day(String iso) {
  final d = DateTime.parse(iso);
  return '${d.day} ${_monthShort[d.month - 1]} ${d.year}';
}

/// One dialog for all three kinds, so the fields stay consistent.
class _AddDialog extends StatefulWidget {
  const _AddDialog({required this.kind, this.initial});
  final String kind; // obligation, debt, goal
  final Object? initial; // set when changing an existing item

  @override
  State<_AddDialog> createState() => _AddDialogState();
}

class _AddDialogState extends State<_AddDialog> {
  final name = TextEditingController();
  final a = TextEditingController(); // amount / balance / target
  final b = TextEditingController(); // rate / saved
  final d = TextEditingController(); // monthly payment / months left
  String frequency = 'monthly', category = 'housing';
  DateTime? due;            // a bill's next due date (optional)
  String? error;

  String _txt(double v) => v == 0 ? '' : (v == v.roundToDouble() ? v.round().toString() : v.toString());

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i is Obligation) {
      name.text = i.name;
      a.text = _txt(i.amount);
      frequency = i.frequency;
      category = i.category;
      due = i.nextDue == null ? null : DateTime.parse(i.nextDue!);
    } else if (i is Debt) {
      name.text = i.name;
      a.text = _txt(i.balance);
      b.text = _txt(i.annualRate);
      d.text = _txt(i.monthlyPayment);
    } else if (i is Goal) {
      name.text = i.name;
      a.text = _txt(i.target);
      b.text = _txt(i.saved);
      d.text = '${i.deadline != null ? Goal.monthsUntil(i.deadline!) : i.monthsLeft}';
    }
  }

  @override
  void dispose() {
    for (final t in [name, a, b, d]) {
      t.dispose();
    }
    super.dispose();
  }

  double? _n(TextEditingController t) => double.tryParse(t.text.replaceAll(',', '').trim());

  String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: due ?? now,
        firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 2));
    if (d != null) setState(() => due = d);
  }

  void _submit() {
    final n = name.text.trim();
    Object? item;
    if (widget.kind == 'obligation' && n.isNotEmpty && (_n(a) ?? 0) > 0) {
      final old = widget.initial is Obligation ? widget.initial as Obligation : null;
      item = Obligation(name: n, amount: _n(a)!, frequency: frequency, category: category,
          nextDue: due == null ? null : _iso(due!),
          lastPaid: old?.lastPaid);
    } else if (widget.kind == 'debt' && n.isNotEmpty && (_n(a) ?? 0) > 0 && (_n(d) ?? 0) > 0) {
      item = Debt(name: n, balance: _n(a)!, annualRate: _n(b) ?? 0, monthlyPayment: _n(d)!);
    } else if (widget.kind == 'goal' && n.isNotEmpty && (_n(a) ?? 0) > 0 && (_n(d) ?? 0) >= 1) {
      final months = _n(d)!.round();
      item = Goal(name: n, target: _n(a)!, saved: _n(b) ?? 0, monthsLeft: months, deadline: Goal.deadlineIn(months));
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
      title: Text('${widget.initial == null ? 'Add' : 'Change'} '
          '${k == 'obligation' ? 'a bill or obligation' : k == 'debt' ? 'a debt' : 'a savings goal'}'),
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
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: Text(due == null ? 'Next due date (optional)' : 'Next due ${_day(_iso(due!))}'),
              subtitle: const Text('Lets the app remind you when it is due.'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (due != null) IconButton(tooltip: 'No due date', icon: const Icon(Icons.close),
                    onPressed: () => setState(() => due = null)),
                TextButton(onPressed: _pickDue, child: Text(due == null ? 'Set' : 'Change')),
              ]),
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
        FilledButton(onPressed: _submit, child: Text(widget.initial == null ? 'Add' : 'Save')),
      ],
    );
  }
}
