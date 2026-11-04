import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/profile.dart';
import '../models/transaction.dart' show spendingCategories;
import '../services/api.dart';
import '../state/app_state.dart';

String kes(num v) => 'KES ${v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')}';

/// Step 1 of the journey: who is in the household and what money comes in.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Profile draft;

  @override
  void initState() {
    super.initState();
    final saved = context.read<AppState>().profile;
    draft = saved == null ? Profile() : Profile.fromJson(saved.toJson()); // edit a copy
  }

  Future<void> _addIncome() async {
    final source = await showDialog<IncomeSource>(context: context, builder: (_) => const _IncomeDialog());
    if (source != null) setState(() => draft.incomes.add(source));
  }

  Future<void> _save() async {
    if (draft.incomes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one source of income.')),
      );
      return;
    }
    try {
      await context.read<AppState>().saveProfile(draft);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your household')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Who lives in your household?', style: theme.textTheme.titleMedium),
          _Counter(
            label: 'People in the household (including you)',
            value: draft.householdSize,
            min: 1,
            onChanged: (v) => setState(() {
              draft.householdSize = v;
              if (draft.dependants >= v) draft.dependants = v - 1;
            }),
          ),
          _Counter(
            label: 'Dependants (people you support)',
            value: draft.dependants,
            min: 0,
            max: draft.householdSize - 1,
            onChanged: (v) => setState(() => draft.dependants = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: draft.urbanRural,
            decoration: const InputDecoration(labelText: 'Where do you live?'),
            items: const [
              DropdownMenuItem(value: 'urban', child: Text('Town or city')),
              DropdownMenuItem(value: 'peri_urban', child: Text('Edge of town')),
              DropdownMenuItem(value: 'rural', child: Text('Countryside')),
            ],
            onChanged: (v) => setState(() => draft.urbanRural = v!),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('I have a formal, salaried job'),
            value: draft.formalJob,
            onChanged: (v) => setState(() => draft.formalJob = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('I pay my own school or university fees'),
            subtitle: const Text('Turn off if parents, a sponsor or HELB pay the institution directly.'),
            value: draft.paysOwnFees,
            onChanged: (v) => setState(() => draft.paysOwnFees = v),
          ),
          const Divider(height: 32),
          Text('Money coming in', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Salary, allowance from home, HELB, side hustle… Add each one with how often it comes.',
              style: theme.textTheme.bodySmall),
          ...draft.incomes.asMap().entries.map((e) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(e.value.name),
                subtitle: Text('${kes(e.value.amount)} ${frequencyLabel[e.value.frequency]}'
                    '${e.value.frequency == 'monthly' ? '' : '  ≈ ${kes(e.value.monthly)} a month'}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => draft.incomes.removeAt(e.key)),
                ),
              )),
          TextButton.icon(onPressed: _addIncome, icon: const Icon(Icons.add), label: const Text('Add income')),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: const Text('Total per month'),
              trailing: Text(kes(draft.monthlyIncome), style: theme.textTheme.titleLarge),
            ),
          ),
          const Divider(height: 32),
          Text('Money already saved', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('M-Shwari, SACCO, bank or cash you keep aside. Used to check if savings can carry a short-term cost.',
              style: theme.textTheme.bodySmall),
          TextFormField(
            initialValue: draft.savingsBalance == 0 ? '' : draft.savingsBalance.round().toString(),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Savings (KES)', hintText: '0'),
            onChanged: (v) => draft.savingsBalance = double.tryParse(v.replaceAll(',', '')) ?? 0,
          ),
          const Divider(height: 32),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            initiallyExpanded: draft.estimates.isEmpty,
            title: Text('Your usual month (rough is fine)', style: theme.textTheme.titleMedium),
            subtitle: Text('Optional. Lets the app give answers today. Your real records replace these '
                'once a full month is recorded.', style: theme.textTheme.bodySmall),
            children: spendingCategories.entries
                .where((e) => e.key != 'savings')
                .map((e) => TextFormField(
                      initialValue: (draft.estimates[e.key] ?? 0) == 0 ? '' : draft.estimates[e.key]!.round().toString(),
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: '${e.value} per month (KES)', hintText: '0'),
                      onChanged: (v) {
                        final n = double.tryParse(v.replaceAll(',', '')) ?? 0;
                        if (n > 0) {
                          draft.estimates[e.key] = n;
                        } else {
                          draft.estimates.remove(e.key);
                        }
                      },
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.label, required this.value, required this.onChanged, this.min = 0, this.max = 30});

  final String label;
  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(onPressed: value > min ? () => onChanged(value - 1) : null, icon: const Icon(Icons.remove)),
          Text('$value', style: Theme.of(context).textTheme.titleMedium),
          IconButton(onPressed: value < max ? () => onChanged(value + 1) : null, icon: const Icon(Icons.add)),
        ],
      );
}

class _IncomeDialog extends StatefulWidget {
  const _IncomeDialog();

  @override
  State<_IncomeDialog> createState() => _IncomeDialogState();
}

class _IncomeDialogState extends State<_IncomeDialog> {
  final _name = TextEditingController();
  final _amount = TextEditingController();
  String _frequency = 'monthly';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_amount.text.replaceAll(',', '').trim());
    if (_name.text.trim().isEmpty || amount == null || amount <= 0) {
      setState(() => _error = 'Enter a name and an amount above 0.');
      return;
    }
    Navigator.of(context).pop(IncomeSource(name: _name.text.trim(), amount: amount, frequency: _frequency));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add income'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name, e.g. Salary or HELB')),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount (KES)'),
            ),
            DropdownButtonFormField<String>(
              initialValue: _frequency,
              decoration: const InputDecoration(labelText: 'How often'),
              items: frequencyLabel.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) => setState(() => _frequency = v!),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _submit, child: const Text('Add')),
        ],
      );
}
