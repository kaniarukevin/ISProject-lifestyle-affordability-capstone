import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../widgets/panel.dart';
import 'profile_screen.dart' show kes;
import 'payees_screen.dart';
import 'statement_screen.dart';

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
  'October', 'November', 'December'];

/// Step 3 of the journey: what the household actually spends. Every other screen builds on these records.
class SpendingScreen extends StatefulWidget {
  const SpendingScreen({super.key});

  @override
  State<SpendingScreen> createState() => _SpendingScreenState();
}

class _SpendingScreenState extends State<SpendingScreen> {
  List<Map<String, dynamic>>? months;    // one summary line per month, newest first
  bool hasStatement = false;
  // A month's records are fetched when its card is opened, once (a year of statements is 1,000+ records).
  final Map<String, Future<List<Txn>>> _items = {};
  String? error;
  final _search = TextEditingController();
  String _query = '';
  Future<List<Txn>>? _all;              // every record, fetched once, the first time you search
  Future<List<Txn>>? _found;            // the current search

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Records matching the search: payee, label, statement text, category, or an amount like 1240 or 1,240.
  Future<List<Txn>> _matches() async {
    final all = await (_all ??= api.getTransactions());
    final q = _query.toLowerCase().replaceAll(',', '').trim();
    return all.where((t) {
      final text = '${t.title} ${t.payee ?? ''} ${t.description} ${categoryLabel(t.category)}'.toLowerCase();
      return text.contains(q) || t.amount.round().toString().contains(q);
    }).take(200).toList();
  }

  Api get api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await api.spendingSummary();
      if (!mounted) return;
      setState(() {
        months = ((s['months'] as List?) ?? []).cast<Map<String, dynamic>>();
        hasStatement = s['has_statement'] == true;
        _items.clear();
        _all = null;
        error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        months ??= [];
        error = e.message;
      });
    }
  }

  Future<List<Txn>> _month(String key) => _items.putIfAbsent(key, () => api.getTransactions(month: key));

  Future<void> _add() async {
    final t = await showDialog<Txn>(context: context, builder: (_) => const _AddTxnDialog());
    if (t == null) return;
    try {
      await api.addTransactions([t]);
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// A record typed in by hand: change anything about it (statement records keep the statement's figures).
  Future<void> _edit(Txn t) async {
    final changed = await showDialog<Txn>(context: context, builder: (_) => _AddTxnDialog(initial: t));
    if (changed == null) return;
    try {
      await api.editTransaction(t.id!, {'amount': changed.amount, 'date': changed.isoDate,
          'description': changed.description, 'category': changed.category, 'one_off': changed.oneOff});
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(Txn t) async {
    try {
      await api.deleteTransaction(t.id!);
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (months == null) return const Center(child: CircularProgressIndicator());
    final groups = months!;
    return Scaffold(
      appBar: AppBar(title: const Text('Your records')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add spending'),
      ),
      body: PageWidth(child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search: Naivas, rent, 1,240…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                      ),
              ),
              onChanged: (v) => setState(() {
                _query = v;
                _found = v.trim().isEmpty ? null : _matches();
              }),
            ),
            const SizedBox(height: 12),
            if (_query.trim().isNotEmpty)
              FutureBuilder<List<Txn>>(
                future: _found,
                builder: (context, snap) {
                  if (snap.hasError) return const Padding(padding: EdgeInsets.all(16), child: Text('Could not search. Pull down to retry.'));
                  if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                  final found = snap.data!;
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(found.isEmpty ? 'Nothing matches "$_query".'
                        : '${found.length}${found.length == 200 ? '+' : ''} record(s) · total ${kes(found.fold<double>(0, (a, t) => a + t.amount))}',
                        style: theme.textTheme.bodyMedium),
                    for (final t in found)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(t.title),
                        subtitle: Text('${t.date.day} ${_monthNames[t.date.month - 1]} ${t.date.year} · ${categoryLabel(t.category)}'
                            '${t.oneOff ? ' · one-off' : ''}'),
                        trailing: Text(kes(t.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                        onTap: () async {
                          if (t.source != 'mpesa') return _edit(t);
                          if (await showCorrectSheet(context, t)) _load();
                        },
                      ),
                  ]);
                },
              )
            else ...[
            Text('Upload your M-PESA statement to bring in months of spending at once, or add spending by hand.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.upload_file),
                label: const Text('Upload M-PESA statement'),
                onPressed: () async {
                  final done = await Navigator.of(context)
                      .push<bool>(MaterialPageRoute(builder: (_) => const StatementScreen()));
                  if (done == true) _load();
                },
              ),
              if (hasStatement)
                OutlinedButton.icon(
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Who you pay'),
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PayeesScreen()));
                    _load();
                  },
                ),
            ]),
            if (groups.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Tap any payment to change what it is.', style: theme.textTheme.bodySmall),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (groups.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: Text('Nothing yet. Tap "Add spending" to record your first expense.')),
              ),
            ...groups.map((g) => _MonthCard(
                  summary: g,
                  expanded: g == groups.first,
                  load: _month,
                  onDelete: _delete,
                  onTap: (t) async {
                    if (t.source != 'mpesa') return _edit(t);
                    if (await showCorrectSheet(context, t)) _load();
                  },
                )),
            ],
          ],
        ),
      )),
    );
  }
}

class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.summary, required this.load, required this.onDelete, required this.onTap,
      this.expanded = false});
  final Map<String, dynamic> summary;
  final Future<List<Txn>> Function(String month) load;
  final bool expanded;
  final void Function(Txn) onDelete;
  final void Function(Txn) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final year = summary['year'] as int, month = summary['month'] as int;
    final key = '$year-${month.toString().padLeft(2, '0')}';
    final total = summary['total'] as num, oneOff = summary['one_off'] as num;
    final cats = (summary['by_category'] as Map).cast<String, num>().entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: ExpansionTile(
        initiallyExpanded: expanded, // only the latest month: a statement can bring in over a thousand records
        title: Text('${_monthNames[month - 1]} $year'),
        subtitle: Text('${kes(total)} · ${summary['count']} records'
            '${oneOff > 0 ? ' · one-off ${kes(oneOff)}' : ''}'),
        // Collapsed cards build no children, so a month's records are only fetched once it is opened.
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: cats
                  .map((e) => Chip(label: Text('${categoryLabel(e.key)}: ${kes(e.value)}',
                      style: theme.textTheme.bodySmall)))
                  .toList(),
            ),
          ),
          FutureBuilder<List<Txn>>(
            future: load(key),
            builder: (context, snap) {
              if (snap.hasError) {
                return const Padding(padding: EdgeInsets.all(16), child: Text('Could not load this month. Pull down to retry.'));
              }
              if (!snap.hasData) {
                return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
              }
              return Column(children: snap.data!.map((t) => ListTile(
                dense: true,
                onTap: () => onTap(t),
                title: Text(t.title),
                subtitle: Text('${t.oneOff ? 'One-off · ' : ''}${t.date.day} ${_monthNames[t.date.month - 1]} · '
                    '${t.type != null ? '${mpesaTypes[t.type] ?? t.type} · ' : ''}${categoryLabel(t.category)}'
                    '${t.pinned ? ' (changed by you)' : ''}'
                    // The line exactly as it appears on the statement, kept next to the app's label.
                    '${t.source == 'mpesa' && t.description.isNotEmpty && t.description != t.title ? '\n${t.description}' : ''}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(kes(t.amount)),
                  IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => onDelete(t)),
                ]),
              )).toList());
            },
          ),
        ],
      ),
    );
  }
}

/// Add spending, or change a typed-in record ([initial]).
class _AddTxnDialog extends StatefulWidget {
  const _AddTxnDialog({this.initial});
  final Txn? initial;

  @override
  State<_AddTxnDialog> createState() => _AddTxnDialogState();
}

class _AddTxnDialogState extends State<_AddTxnDialog> {
  late final amount = TextEditingController(text: widget.initial == null ? '' : widget.initial!.amount.round().toString());
  late final note = TextEditingController(text: widget.initial?.description ?? '');
  late String category = widget.initial?.category ?? 'food_groceries';
  late DateTime date = widget.initial?.date ?? DateTime.now();
  late bool oneOff = widget.initial?.oneOff ?? false;
  String? error;

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: date,
        firstDate: DateTime(now.year - 2), lastDate: now);
    if (d != null) setState(() => date = d);
  }

  void _submit() {
    final a = double.tryParse(amount.text.replaceAll(',', '').trim());
    if (a == null || a <= 0) {
      setState(() => error = 'Enter an amount above 0.');
      return;
    }
    Navigator.of(context).pop(Txn(date: date, amount: a, category: category, description: note.text.trim(), oneOff: oneOff));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? 'Add spending' : 'Change this record'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [
            TextField(controller: amount, autofocus: true, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount (KES)')),
            DropdownButtonFormField<String>(
              initialValue: category,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'What was it for?'),
              items: {
                ...spendingCategories,
                // A record sorted into a category outside the list (e.g. Shopping) keeps it as a choice.
                if (!spendingCategories.containsKey(category)) category: categoryLabel(category),
              }.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setState(() => category = v!),
            ),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)',
                helperText: 'e.g. Naivas, matatu to town')),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event),
              title: Text('${date.day} ${_monthNames[date.month - 1]} ${date.year}'),
              trailing: TextButton(onPressed: _pickDate, child: const Text('Change')),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('One-off purchase'),
              subtitle: const Text('Big, rare payments like a plot, a car deposit or a wedding. '
                  'Shown, but not counted as your usual spending. Put any loan for it under Commitments.'),
              value: oneOff,
              onChanged: (v) => setState(() => oneOff = v),
            ),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _submit, child: Text(widget.initial == null ? 'Add' : 'Save')),
        ],
      );
}
