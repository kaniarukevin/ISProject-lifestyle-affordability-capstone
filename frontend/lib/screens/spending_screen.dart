import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import 'profile_screen.dart' show kes;

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
  'October', 'November', 'December'];

/// Step 3 of the journey: what the household actually spends. Every other screen builds on these records.
class SpendingScreen extends StatefulWidget {
  const SpendingScreen({super.key});

  @override
  State<SpendingScreen> createState() => _SpendingScreenState();
}

class _SpendingScreenState extends State<SpendingScreen> {
  List<Txn>? txns;
  String? error;

  Api get api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await api.getTransactions();
      setState(() {
        txns = t;
        error = null;
      });
    } on ApiException catch (e) {
      setState(() {
        txns ??= [];
        error = e.message;
      });
    }
  }

  Future<void> _add() async {
    final t = await showDialog<Txn>(context: context, builder: (_) => const _AddTxnDialog());
    if (t == null) return;
    try {
      final saved = await api.addTransactions([t]);
      setState(() => txns!.addAll(saved));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(Txn t) async {
    try {
      await api.deleteTransaction(t.id!);
      setState(() => txns!.removeWhere((x) => x.id == t.id));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (txns == null) return const Center(child: CircularProgressIndicator());
    final groups = groupByMonth(txns!);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add spending'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            Text('Your spending', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text('Add what you spend. A few weeks of records is enough for your budget and forecast to start '
                'working; statement upload is coming.', style: theme.textTheme.bodySmall),
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
            ...groups.map((g) => _MonthCard(group: g, onDelete: _delete)),
          ],
        ),
      ),
    );
  }
}

class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.group, required this.onDelete});
  final MonthGroup group;
  final void Function(Txn) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cats = group.byCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text('${_monthNames[group.month - 1]} ${group.year}'),
        subtitle: Text('${kes(group.total)} · ${group.items.length} records'
            '${group.oneOffTotal > 0 ? ' · one-off ${kes(group.oneOffTotal)}' : ''}'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: cats
                  .map((e) => Chip(label: Text('${spendingCategories[e.key] ?? e.key}: ${kes(e.value)}',
                      style: theme.textTheme.bodySmall)))
                  .toList(),
            ),
          ),
          ...group.items.map((t) => ListTile(
                dense: true,
                title: Text(t.description.isEmpty ? spendingCategories[t.category] ?? t.category : t.description),
                subtitle: Text('${t.oneOff ? 'One-off · ' : ''}${t.date.day} ${_monthNames[t.date.month - 1]} · '
                    '${spendingCategories[t.category]}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(kes(t.amount)),
                  IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => onDelete(t)),
                ]),
              )),
        ],
      ),
    );
  }
}

class _AddTxnDialog extends StatefulWidget {
  const _AddTxnDialog();

  @override
  State<_AddTxnDialog> createState() => _AddTxnDialogState();
}

class _AddTxnDialogState extends State<_AddTxnDialog> {
  final amount = TextEditingController();
  final note = TextEditingController();
  String category = 'food_groceries';
  DateTime date = DateTime.now();
  bool oneOff = false;
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
        title: const Text('Add spending'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: amount, autofocus: true, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount (KES)')),
            DropdownButtonFormField<String>(
              initialValue: category,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'What was it for?'),
              items: spendingCategories.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
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
          FilledButton(onPressed: _submit, child: const Text('Add')),
        ],
      );
}
