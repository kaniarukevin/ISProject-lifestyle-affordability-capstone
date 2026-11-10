import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/profile.dart';
import '../models/transaction.dart' show spendingCategories;
import '../services/api.dart';
import '../state/app_state.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/panel.dart';
import 'password_field.dart';
import 'privacy_screen.dart';

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

  Future<void> _download() => downloadMyData(context);

  Future<void> _editIncome(int i) async {
    final source = await showDialog<IncomeSource>(
        context: context, builder: (_) => _IncomeDialog(initial: draft.incomes[i]));
    if (source != null) setState(() => draft.incomes[i] = source);
  }

  Future<void> _save() async {
    if (draft.incomes.isEmpty && !draft.incomeTypes.contains('none')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one source of income.')),
      );
      return;
    }
    // A different income: did it change (earlier months keep the old figure) or was the old one a mistake?
    var change = 'from_now';
    final before = context.read<AppState>().profile;
    if (before != null && (draft.monthlyIncome - before.monthlyIncome).abs() >= 1) {
      final pick = await showChoiceSheet<String>(
        context,
        title: 'Your income is different',
        message: 'Did your income change, or are you correcting a mistake? If it changed, your past months keep '
            '${kes(before.monthlyIncome)} and ${kes(draft.monthlyIncome)} applies from this month.',
        choices: const [
          SheetChoice('It changed from this month', 'from_now', primary: true),
          SheetChoice("I'm correcting a mistake", 'correction'),
        ],
      );
      if (pick == null || !mounted) return;
      change = pick;
    }
    try {
      await context.read<AppState>().saveProfile(draft, incomeChange: change);
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
      body: PageWidth(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            initialValue: draft.name ?? '',
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'What should we call you?'),
            onChanged: (v) => draft.name = v.trim().isEmpty ? null : v.trim(),
          ),
          const SizedBox(height: 8),
          Text('How does money come in? Pick all that apply.', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in incomeTypeLabels.entries)
              FilterChip(
                label: Text(e.value),
                showCheckmark: false,
                selected: draft.incomeTypes.contains(e.key),
                onSelected: (on) => setState(() {
                  if (on && e.key == 'none') draft.incomeTypes.clear();
                  if (on && e.key != 'none') draft.incomeTypes.remove('none');
                  on ? draft.incomeTypes.add(e.key) : draft.incomeTypes.remove(e.key);
                  draft.formalJob = draft.incomeTypes.contains('salary');
                }),
              ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("I'm studying"),
            value: draft.studying,
            onChanged: (v) => setState(() => draft.studying = v),
          ),
          const Divider(height: 32),
          Text('Who lives in your household?', style: theme.textTheme.titleMedium),
          _Counter(
            label: 'People in the household (including you)',
            value: draft.householdSize,
            min: 1,
            onChanged: (v) => setState(() {
              draft.householdSize = v;
              if (draft.dependants >= v) draft.dependants = v - 1;
              if (draft.childrenInSchool >= v) draft.childrenInSchool = v - 1;
            }),
          ),
          _Counter(
            label: 'People who depend on your money (not you)',
            value: draft.dependants,
            min: 0,
            max: draft.householdSize - 1,
            onChanged: (v) => setState(() => draft.dependants = v),
          ),
          _Counter(
            label: 'Children in school',
            value: draft.childrenInSchool,
            min: 0,
            max: draft.householdSize - 1,
            onChanged: (v) => setState(() => draft.childrenInSchool = v),
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
          if (draft.incomeTypes.isEmpty)               // accounts from before the question was asked
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
                onTap: () => _editIncome(e.key),
                title: Text(e.value.name),
                subtitle: Text('${kes(e.value.amount)} ${frequencyLabel[e.value.frequency]}'
                    '${e.value.frequency == 'monthly' ? '' : '  ≈ ${kes(e.value.monthly)} a month'}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => draft.incomes.removeAt(e.key)),
                ),
              )),
          if (draft.incomes.isNotEmpty)
            Text('Tap an income to change it.', style: theme.textTheme.bodySmall),
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
          // Only for an existing account: the first-time setup screen has nothing to delete yet.
          if (context.read<AppState>().profile != null) ...[
            const Divider(height: 40),
            Text('Your account', style: theme.textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: const Text('Change password'),
              onTap: () => showDialog<void>(context: context, builder: (_) => const _PasswordDialog()),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.download_outlined),
              title: const Text('Download my data'),
              subtitle: const Text('Everything the app keeps about you, in one file'),
              onTap: _download,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('How this app uses your data'),
              onTap: () => showPrivacy(context, context.read<AppState>().api),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
              title: Text('Delete my account', style: TextStyle(color: theme.colorScheme.error)),
              subtitle: const Text('Removes everything, permanently'),
              onTap: () => confirmDeleteAccount(context),
            ),
          ],
        ],
      )),
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

/// Add an income, or change one ([initial]).
class _IncomeDialog extends StatefulWidget {
  const _IncomeDialog({this.initial});
  final IncomeSource? initial;

  @override
  State<_IncomeDialog> createState() => _IncomeDialogState();
}

class _IncomeDialogState extends State<_IncomeDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _amount = TextEditingController(text: widget.initial == null ? '' : widget.initial!.amount.round().toString());
  late String _frequency = widget.initial?.frequency ?? 'monthly';
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
        title: Text(widget.initial == null ? 'Add income' : 'Change income'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
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
          FilledButton(onPressed: _submit, child: Text(widget.initial == null ? 'Add' : 'Save')),
        ],
      );
}


/// Change the password: the current one, then the new one twice. This device stays logged in; others are logged out.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_current, _new, _again]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_new.text.length < 8) {
      setState(() => _error = 'The new password must be at least 8 characters.');
      return;
    }
    if (_new.text != _again.text) {
      setState(() => _error = 'The two new passwords are not the same.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().changePassword(_current.text, _new.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Password changed. Any other phone or computer will need to log in again.')));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Change password'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [
            PasswordField(controller: _current, label: 'Current password', autofillHints: const [AutofillHints.password]),
            PasswordField(controller: _new, label: 'New password', helper: 'At least 8 characters',
                autofillHints: const [AutofillHints.newPassword]),
            PasswordField(controller: _again, label: 'New password again', onSubmitted: (_) => _submit()),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _submit, child: const Text('Change')),
        ],
      );
}
