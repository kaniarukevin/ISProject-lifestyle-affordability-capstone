import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/commitments.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../state/reload_on_change.dart';
import '../theme/app_theme.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/format.dart';
import '../widgets/panel.dart';
import '../widgets/busy_words.dart';

/// Step 2 of the journey: rent, fees, debts and goals, turned into monthly figures by the /commitments engine.
class CommitmentsScreen extends StatefulWidget {
  const CommitmentsScreen({super.key});

  @override
  State<CommitmentsScreen> createState() => _CommitmentsScreenState();
}

class _CommitmentsScreenState extends State<CommitmentsScreen> with ReloadOnChange {
  @override
  Future<void> reloadQuietly() => _load();

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
      if (!mounted) return;
      setState(() {
        c = Commitments.fromJson(data);
        summary = (data['summary'] as Map?)?.cast<String, dynamic>() ?? summary;
      });
      // Goals saved before deadlines existed get one now, so they start counting down. Saved only when that
      // changed something: saving on every load would make every screen reload after each visit here.
      var filled = false;
      for (final g in c!.goals) {
        if (g.deadline == null && !g.done) {
          g.deadline = Goal.deadlineIn(g.monthsLeft);
          filled = true;
        }
      }
      if (filled) await _save(quiet: true);
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

  /// Delete after asking, so a mis-tap does not lose a bill, debt or goal.
  Future<void> _confirmRemove(String what, VoidCallback removal) async {
    final sure = await showChoiceSheet<bool>(context,
        title: 'Remove $what?',
        message: 'It is taken out of your plans and your budget stops setting money aside for it.',
        choices: const [SheetChoice('Remove', true, primary: true)]);
    if (sure == true) _remove(removal);
  }

  @override
  Widget build(BuildContext context) {
    if (c == null) return const BusyCenter(plansWords);
    final theme = Theme.of(context);
    final col = AppColors.of(context);
    final s = summary;
    final fixed = (s?['for_budget']?['fixed'] as Map?)?.cast<String, dynamic>() ?? {};
    final monthlyTotal = fixed.values.fold<num>(0, (a, v) => a + (v as num));
    final goalsMonthly = (s?['for_budget']?['goal_per_month'] ?? 0) as num;
    final debts = s?['debts'] as Map<String, dynamic>?;
    final owed = c!.debts.fold<double>(0, (a, d) => a + d.balance);
    final warnings = ((s?['warnings'] as List?) ?? []).cast<String>();
    final muted = theme.textTheme.bodyMedium?.copyWith(color: col.muted);

    Widget stat(String label, String value, [String? note]) => Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: muted),
            const SizedBox(height: 4),
            Text(value, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (note != null) ...[const SizedBox(height: 4), Text(note, style: theme.textTheme.bodySmall?.copyWith(color: col.muted))],
          ]),
        );

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          Text('Money you have to pay, or want to save, every month. Tosha sets it aside first, then plans the rest.',
              style: muted),
          if (busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
          if (error != null)
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: TextStyle(color: col.warn))),
          const SizedBox(height: 16),
          CardRow(minWidth: 220, children: [
            stat('Bills and debts each month', 'KES ${money(monthlyTotal)}'),
            stat('Debts left', 'KES ${money(owed)}',
                debts == null ? null : debts['as_planned']['debt_free_by'] != null
                    ? 'Debt-free by ${debts['as_planned']['debt_free_by']}'
                    : 'Some debts are never cleared at these payments'),
            stat('Towards goals each month', 'KES ${money(goalsMonthly)}'),
          ]),
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 20),
            Panel(
              color: col.warnBg,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final w in warnings)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(w, style: theme.textTheme.bodyMedium?.copyWith(color: col.warn, fontWeight: FontWeight.w600)),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          CardRow(minWidth: 300, children: [
            _Section(
              title: 'Bills',
              note: 'Rent, school fees, chama, insurance',
              empty: 'No bills yet.',
              onAdd: () => _add('obligation'),
              children: c!.obligations.asMap().entries.map((e) {
                final row = (s?['obligations'] as List?)?.elementAtOrNull(e.key) as Map?;
                final status = row?['status'] as String?;
                final days = row?['due_in_days'] as int?;
                final due = e.value.nextDue == null
                    ? ''
                    : status == 'overdue'
                        ? ' · late since ${_day(e.value.nextDue!)}'
                        : status == 'due_soon'
                            ? ' · due ${days == 0 ? 'today' : 'in $days day(s)'}'
                            : ' · next ${_day(e.value.nextDue!)}';
                return _Row(
                  title: e.value.name,
                  amount: money(e.value.amount),
                  subtitle: '${_capital(obligationFrequencies[e.value.frequency] ?? '')}$due${_fromCheck(e.value.fromCheck)}',
                  subtitleColor: status == 'overdue' ? col.warn : null,
                  onTap: () => _edit('obligation', e.value, (x) => c!.obligations[e.key] = x as Obligation),
                  onDelete: () => _confirmRemove(e.value.name, () => c!.obligations.removeAt(e.key)),
                  extra: e.value.nextDue == null
                      ? null
                      : TextButton(onPressed: busy ? null : () => _markPaid(e.key), child: const Text('Paid')),
                );
              }).toList(),
            ),
            _Section(
              title: 'Debts',
              note: 'Fuliza, M-Shwari, SACCO or bank loan, phone on credit',
              empty: 'No debts. Add Fuliza, a SACCO or bank loan, or a phone on credit if you have any.',
              onAdd: () => _add('debt'),
              children: [
                ...c!.debts.asMap().entries.map((e) {
                  final plan = (debts?['as_planned']?['debts'] as List?)?.elementAtOrNull(e.key) as Map?;
                  return _Row(
                    title: e.value.name,
                    amount: '${money(e.value.monthlyPayment)} a month',
                    subtitle: 'KES ${money(e.value.balance)} still owed · ${e.value.annualRate}% interest a year'
                        '${plan != null && plan['cleared_by'] != null ? ' · paid off by ${plan['cleared_by']}' : ''}'
                        '${_fromCheck(e.value.fromCheck)}',
                    onTap: () => _edit('debt', e.value, (x) => c!.debts[e.key] = x as Debt),
                    onDelete: () => _confirmRemove(e.value.name, () => c!.debts.removeAt(e.key)),
                  );
                }),
                if (c!.debts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: col.field, borderRadius: BorderRadius.circular(20)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('What if I pay a bit more each month?', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: c!.extraPerMonth == 0 ? '' : c!.extraPerMonth.round().toString(),
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(prefixText: 'KES ', hintText: '1,000',
                            fillColor: theme.colorScheme.surface),
                        onFieldSubmitted: (v) {
                          final x = double.tryParse(v.replaceAll(',', ''));
                          c!.extraPerMonth = x != null && x.isFinite && x >= 0 && x < 100000000 ? x : 0;
                          _save(quiet: true);
                        },
                      ),
                      if (debts?['extra_saves'] != null) ...[
                        const SizedBox(height: 8),
                        Text('Debt-free ${debts!['extra_saves']['months']} month(s) sooner, '
                            'KES ${money(debts['extra_saves']['interest_KES'] as num)} less interest.',
                            style: theme.textTheme.bodyMedium),
                      ],
                    ]),
                  ),
                ],
              ],
            ),
            _Section(
              title: 'Goals',
              note: 'An emergency fund, a plot, a trip',
              empty: 'No goals yet. Add one, like an emergency fund, and Tosha sets money aside for it in your budget.',
              onAdd: () => _add('goal'),
              children: c!.goals.asMap().entries.map((e) {
                // Matched by name: the server's list leaves reached goals out, so positions differ.
                final g = ((s?['goals'] as List?) ?? []).cast<Map>().where((x) => x['name'] == e.value.name).firstOrNull;
                final share = e.value.target <= 0 ? 0.0 : (e.value.saved / e.value.target).clamp(0, 1).toDouble();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: e.value.done ? null : () => _edit('goal', e.value, (x) => c!.goals[e.key] = x as Goal),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(e.value.name, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                            if (e.value.fromCheck != null)
                              Text('F${_fromCheck(e.value.fromCheck).substring(4)}',
                                  style: theme.textTheme.bodySmall?.copyWith(color: col.muted)),
                          ]),
                        ),
                        if (e.value.done)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(color: col.lime, borderRadius: BorderRadius.circular(12)),
                            child: const Text('Reached', style: TextStyle(color: Color(0xFF111111), fontWeight: FontWeight.w600, fontSize: 13)),
                          ),
                        IconButton(
                          tooltip: 'Remove ${e.value.name}',
                          icon: const Icon(Icons.delete_outline_rounded, size: 20),
                          onPressed: () => _confirmRemove(e.value.name, () => c!.goals.removeAt(e.key)),
                        ),
                      ]),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: LinearProgressIndicator(value: e.value.done ? 1 : share, minHeight: 10),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        e.value.done
                            ? 'KES ${money(e.value.target)}${e.value.doneOn != null ? ' · reached ${e.value.doneOn}' : ''}'
                            : 'KES ${money(e.value.saved)} of KES ${money(e.value.target)} saved'
                                '${g != null ? ' · KES ${money(g['monthly_needed_KES'] as num)} a month to reach it' : ''}'
                                ' in ${e.value.monthsLeft} month${e.value.monthsLeft == 1 ? '' : 's'}',
                        style: theme.textTheme.bodySmall?.copyWith(color: col.muted),
                      ),
                    ]),
                  ),
                );
              }).toList(),
            ),
          ]),
        ],
      ),
    );
  }
}

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.note, required this.empty, required this.onAdd, required this.children});
  final String title, note, empty;
  final VoidCallback onAdd;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final col = AppColors.of(context);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.titleLarge),
              Text(note, style: theme.textTheme.bodySmall?.copyWith(color: col.muted)),
            ]),
          ),
          IconButton.filledTonal(
            tooltip: 'Add to $title',
            style: IconButton.styleFrom(backgroundColor: col.field, foregroundColor: theme.colorScheme.onSurface),
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
          ),
        ]),
        const SizedBox(height: 14),
        if (children.isEmpty) Text(empty, style: theme.textTheme.bodyMedium?.copyWith(color: col.muted)),
        ...children,
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.amount, required this.subtitle, required this.onDelete, this.onTap,
      this.extra, this.subtitleColor});
  final String title, amount, subtitle;
  final VoidCallback onDelete;
  final VoidCallback? onTap;      // change it
  final Widget? extra;            // e.g. "Paid"
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final col = AppColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
              Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: subtitleColor ?? col.muted)),
            ]),
          ),
          Text(amount, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          ?extra,
          IconButton(tooltip: 'Remove $title', icon: const Icon(Icons.delete_outline_rounded, size: 20), onPressed: onDelete),
        ]),
      ),
    );
  }
}

const _monthShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// '2026-12-05' -> '5 Dec 2026'.
/// ' · from a check on 9 Nov' for items added by going ahead with a 'Can I afford it?' check.
String _fromCheck(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso);
  return d == null ? '' : ' · from a check on ${d.day} ${_monthShort[d.month - 1]}';
}

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
        child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [
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
              subtitle: const Text('Tosha shows it under "Coming up" on the home tab a week before it is due.'),
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
