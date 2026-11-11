import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/profile.dart';
import '../models/transaction.dart' show spendingCategories;
import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/info_note.dart';
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
    final c = AppColors.of(context);
    final existing = context.read<AppState>().profile != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Your household')),
      body: PageWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _Section(
              icon: Icons.person_outline_rounded,
              title: 'About you',
              children: [
                TextFormField(
                  initialValue: draft.name ?? '',
                  maxLength: 40,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'What should we call you?', counterText: ''),
                  onChanged: (v) => draft.name = v.trim().isEmpty ? null : v.trim(),
                ),
                const SizedBox(height: 16),
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
                _Toggle(
                  label: "I'm studying",
                  value: draft.studying,
                  onChanged: (v) => setState(() => draft.studying = v),
                ),
                _Toggle(
                  label: 'I pay my own school or university fees',
                  help: 'Turn this off if parents, a sponsor or HELB pay the institution directly.',
                  value: draft.paysOwnFees,
                  onChanged: (v) => setState(() => draft.paysOwnFees = v),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              icon: Icons.work_outline_rounded,
              title: 'How money comes in',
              subtitle: 'Pick all that apply.',
              children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in incomeTypeLabels.entries)
                    FilterChip(
                      label: Text(e.value),
                      selected: draft.incomeTypes.contains(e.key),
                      onSelected: (on) => setState(() {
                        if (on && e.key == 'none') draft.incomeTypes.clear();
                        if (on && e.key != 'none') draft.incomeTypes.remove('none');
                        on ? draft.incomeTypes.add(e.key) : draft.incomeTypes.remove(e.key);
                        draft.formalJob = draft.incomeTypes.contains('salary');
                      }),
                    ),
                ]),
                // Accounts made before this question existed still need the old switch.
                if (draft.incomeTypes.isEmpty)
                  _Toggle(
                    label: 'I have a formal, salaried job',
                    value: draft.formalJob,
                    onChanged: (v) => setState(() => draft.formalJob = v),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              icon: Icons.people_outline_rounded,
              title: 'Who lives with you',
              children: [
                _Counter(
                  label: 'People in the household',
                  help: 'Counting you.',
                  value: draft.householdSize,
                  min: 1,
                  onChanged: (v) => setState(() {
                    draft.householdSize = v;
                    if (draft.dependants >= v) draft.dependants = v - 1;
                    if (draft.childrenInSchool >= v) draft.childrenInSchool = v - 1;
                  }),
                ),
                _Counter(
                  label: 'People who depend on your money',
                  help: 'Anyone whose food, rent or fees your money pays for. Not you.',
                  value: draft.dependants,
                  min: 0,
                  max: draft.householdSize - 1,
                  onChanged: (v) => setState(() => draft.dependants = v),
                ),
                _Counter(
                  label: 'Children in school',
                  help: 'Of the people above, how many are in school or college.',
                  value: draft.childrenInSchool,
                  min: 0,
                  max: draft.householdSize - 1,
                  onChanged: (v) => setState(() => draft.childrenInSchool = v),
                ),
                const InfoNote(
                  text: 'Your money has to cover everyone here. The more people it covers, the harder the same '
                      'income works, and the app takes that into account.',
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              icon: Icons.south_west_rounded,
              title: 'Money coming in',
              subtitle: 'Salary, allowance from home, HELB, a side hustle. Add each one with how often it comes.',
              children: [
                for (final e in draft.incomes.asMap().entries)
                  _IncomeRow(
                    source: e.value,
                    onTap: () => _editIncome(e.key),
                    onRemove: () => setState(() => draft.incomes.removeAt(e.key)),
                  ),
                if (draft.incomes.isEmpty)
                  Text('Nothing added yet.', style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _addIncome,
                    icon: const Icon(Icons.add),
                    label: const Text('Add income'),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(18)),
                  child: Row(children: [
                    Expanded(
                      child: Text('Total per month',
                          style: theme.textTheme.bodyLarge?.copyWith(color: c.onLime, fontWeight: FontWeight.w600)),
                    ),
                    Text(kes(draft.monthlyIncome),
                        style: theme.textTheme.titleLarge?.copyWith(color: c.onLime, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              icon: Icons.savings_outlined,
              title: 'Money already saved',
              subtitle: 'M-Shwari, SACCO, bank or cash you keep aside.',
              children: [
                TextFormField(
                  initialValue: draft.savingsBalance == 0 ? '' : draft.savingsBalance.round().toString(),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Savings (KES)',
                      hintText: '0',
                      helperText: 'Optional. Leave it empty if you have nothing set aside.'),
                  onChanged: (v) => draft.savingsBalance = double.tryParse(v.replaceAll(',', '')) ?? 0,
                ),
                const InfoNote(
                  text: 'Used to check whether savings could carry a one-off cost without pushing you short. '
                      'The app never moves this money.',
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              collapsible: true,
              startOpen: draft.estimates.isEmpty,
              icon: Icons.edit_calendar_outlined,
              title: 'Your usual month',
              subtitle: 'Optional, and rough is fine. It lets the app answer you today; your real records '
                  'replace these once a full month is recorded.',
              children: [
                for (final e in spendingCategories.entries.where((e) => e.key != 'savings'))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: TextFormField(
                      initialValue:
                          (draft.estimates[e.key] ?? 0) == 0 ? '' : draft.estimates[e.key]!.round().toString(),
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                          labelText: '${e.value} per month (KES)',
                          hintText: '0',
                          helperText: 'Optional'),
                      onChanged: (v) {
                        final n = double.tryParse(v.replaceAll(',', '')) ?? 0;
                        if (n > 0) {
                          draft.estimates[e.key] = n;
                        } else {
                          draft.estimates.remove(e.key);
                        }
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _save, child: const Text('Save')),
            // Only for an existing account: the first-time setup screen has nothing to delete yet.
            if (existing) ...[
              const SizedBox(height: 16),
              _Section(
                icon: Icons.settings_outlined,
                title: 'Your account',
                children: [
                  _AccountRow(
                    icon: Icons.lock_outline,
                    title: 'Change password',
                    onTap: () => showDialog<void>(context: context, builder: (_) => const _PasswordDialog()),
                  ),
                  _AccountRow(
                    icon: Icons.download_outlined,
                    title: 'Download my data',
                    subtitle: 'Everything the app keeps about you, in one file',
                    onTap: _download,
                  ),
                  _AccountRow(
                    icon: Icons.privacy_tip_outlined,
                    title: 'How this app uses your data',
                    onTap: () => showPrivacy(context, context.read<AppState>().api),
                  ),
                  _AccountRow(
                    icon: Icons.delete_forever_outlined,
                    title: 'Delete my account',
                    subtitle: 'Removes everything, permanently',
                    danger: true,
                    onTap: () => confirmDeleteAccount(context),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One block of the page: a circled lime icon, a heading, an optional line under it, then the fields. Set
/// [collapsible] for a long optional block, so the page is not a wall of boxes (11 Nov).
class _Section extends StatefulWidget {
  const _Section({
    required this.title,
    required this.children,
    this.icon,
    this.subtitle,
    this.collapsible = false,
    this.startOpen = true,
  });
  final String title;
  final IconData? icon;
  final String? subtitle;
  final List<Widget> children;
  final bool collapsible, startOpen;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  late bool open = !widget.collapsible || widget.startOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final head = Row(children: [
      if (widget.icon != null) ...[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: c.lime, shape: BoxShape.circle),
          child: Icon(widget.icon, size: 19, color: c.onLime),
        ),
        const SizedBox(width: 12),
      ],
      Expanded(child: Text(widget.title, style: theme.textTheme.titleMedium)),
      if (widget.collapsible)
        Icon(open ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, color: c.muted),
    ]);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.collapsible)
          InkWell(onTap: () => setState(() => open = !open), child: head)
        else
          head,
        if (widget.subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(widget.subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: c.muted, height: 1.35)),
          ),
        if (open) ...[
          const SizedBox(height: 18),
          ...widget.children,
        ],
      ]),
    );
  }
}

/// A yes/no setting: the words on the left, the switch on the right, with room between them.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged, this.help});
  final String label;
  final String? help;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: theme.textTheme.bodyLarge),
            if (help != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(help!, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
              ),
          ]),
        ),
        const SizedBox(width: 16),
        Switch(value: value, onChanged: onChanged),
      ]),
    );
  }
}

/// One income: what it is, how much and how often, and a bin to remove it.
class _IncomeRow extends StatelessWidget {
  const _IncomeRow({required this.source, required this.onTap, required this.onRemove});
  final IncomeSource source;
  final VoidCallback onTap, onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: c.field,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(source.name, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                      '${kes(source.amount)} ${frequencyLabel[source.frequency]}'
                      '${source.frequency == 'monthly' ? '' : ' · about ${kes(source.monthly)} a month'}',
                      style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                ]),
              ),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove ${source.name}',
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One row under "Your account".
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final ink = danger ? theme.colorScheme.error : theme.colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Icon(icon, size: 20, color: ink),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.bodyLarge?.copyWith(color: ink)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                ),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.muted),
        ]),
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
    this.min = 0,
    this.max = 30,
  });

  final String label;
  final String? help;
  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: theme.textTheme.bodyLarge),
            if (help != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(help!, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
              ),
          ]),
        ),
        const SizedBox(width: 12),
        Container(
          decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(40)),
          child: Row(children: [
            IconButton(
              onPressed: value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove),
              visualDensity: VisualDensity.compact,
            ),
            SizedBox(
              width: 26,
              child: Text('$value',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            IconButton(
              onPressed: value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add),
              visualDensity: VisualDensity.compact,
            ),
          ]),
        ),
      ]),
    );
  }
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
