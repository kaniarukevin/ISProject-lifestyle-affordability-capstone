import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/info_note.dart';
import '../models/commitments.dart';
import '../models/profile.dart';
import '../models/transaction.dart' show spendingCategories;
import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/panel.dart';
import '../widgets/busy_words.dart';

/// First-time setup, one question at a time: name, how money comes in, who lives with you (children and fees),
/// income, rent and savings, and a rough usual month. About two minutes; the first answer is "based on what
/// you told us" until real records take over.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

const _steps = 6;

/// What a setup step asks of you, shown as a badge beside the step number.
enum _Need { needed, optional, some }

class _OnboardingScreenState extends State<OnboardingScreen> {
  int step = 0;
  bool busy = false;
  String? error;

  final name = TextEditingController();
  final types = <String>{};
  bool studying = false;
  int people = 1, support = 0, children = 0;
  bool? paysChildFees, paysOwnFees, sendsMoney;
  final sendHome = TextEditingController();
  final childFees = TextEditingController();
  final ownFees = TextEditingController();
  final income = TextEditingController();
  bool varies = false;
  final low = TextEditingController();
  final rent = TextEditingController();
  final saved = TextEditingController();
  final usual = {for (final k in _usualKeys) k: TextEditingController()};

  static const _usualKeys = ['food_groceries', 'transport', 'utilities', 'airtime_data', 'entertainment'];

  @override
  void dispose() {
    for (final c in [name, childFees, ownFees, income, low, rent, saved, sendHome, ...usual.values]) {
      c.dispose();
    }
    super.dispose();
  }

  String get first => name.text.trim();

  /// A typed amount: null when empty or not a sensible number (blocks "Infinity", "NaN" and 1e15, audit A-15).
  static double? _amount(TextEditingController c) {
    final v = double.tryParse(c.text.replaceAll(',', '').trim());
    if (v == null || !v.isFinite || v < 0 || v > 100000000) return null;
    return v;
  }

  String? _check() {
    switch (step) {
      case 0:
        return first.isEmpty ? 'Tell us what to call you.' : null;
      case 1:
        return types.isEmpty ? 'Pick at least one, or "Not earning right now".' : null;
      case 2:
        if (children > 0 && paysChildFees == true && _amount(childFees) == null) return 'Add the fees per term.';
        if (studying && paysOwnFees == true && _amount(ownFees) == null) return 'Add your fees per semester.';
        if (sendsMoney == true && _amount(sendHome) == null) return 'Add roughly how much you send a month.';
        return null;
      case 3:
        if (_amount(income) == null) return 'Add how much comes in a usual month (0 is fine).';
        if (varies && low.text.trim().isNotEmpty && _amount(low) == null) return 'The low month needs a number.';
        return null;
      case 4:
        if (rent.text.trim().isNotEmpty && _amount(rent) == null) return 'Rent needs a number.';
        if (saved.text.trim().isNotEmpty && _amount(saved) == null) return 'Savings need a number.';
        return null;
    }
    return null;
  }

  void _next() {
    final problem = _check();
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    if (step == _steps - 1) {
      _finish();
    } else {
      setState(() {
        step++;
        error = null;
      });
    }
  }

  static const _sourceName = {
    'salary': 'Salary',
    'casual': 'Casual work',
    'business': 'Business',
    'farming': 'Farming',
    'support': 'Allowance or support',
    'pension': 'Pension',
  };

  Future<void> _finish() async {
    final state = context.read<AppState>();
    final monthly = _amount(income) ?? 0;
    final earning = types.where((t) => t != 'none').toList();
    final p = Profile(
      householdSize: people,
      dependants: support,
      formalJob: types.contains('salary'),
      paysOwnFees: studying && paysOwnFees == true,
      savingsBalance: _amount(saved) ?? 0,
      incomes: [
        if (monthly > 0)
          IncomeSource(name: earning.length == 1 ? _sourceName[earning.first]! : 'Money in', amount: monthly),
      ],
      estimates: {
        for (final e in usual.entries)
          if ((_amount(e.value) ?? 0) > 0) e.key: _amount(e.value)!,
      },
    )
      ..name = first
      ..incomeTypes = types.toList()
      ..studying = studying
      ..childrenInSchool = children
      ..incomeLow = varies ? _amount(low) : null;
    final bills = Commitments(obligations: [
      if ((_amount(rent) ?? 0) > 0) Obligation(name: 'Rent', amount: _amount(rent)!, category: 'housing'),
      if (children > 0 && paysChildFees == true)
        Obligation(name: 'School fees', amount: _amount(childFees)!, frequency: 'termly', category: 'school_fees'),
      if (studying && paysOwnFees == true)
        Obligation(name: 'My fees', amount: _amount(ownFees)!, frequency: 'semester', category: 'school_fees'),
      // Money sent to people who do not live with you: a monthly commitment, not a member of the household.
      if (sendsMoney == true && (_amount(sendHome) ?? 0) > 0)
        Obligation(name: 'Family support', amount: _amount(sendHome)!, category: 'other_commitments'),
    ]);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await state.api.putProfile(p.toJson());
      if (bills.obligations.isNotEmpty) await state.api.putCommitments(bills.toJson());
      await state.useSavedProfile(p);      // opens the app on Overview
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  if (step > 0)
                    IconButton.filledTonal(
                      tooltip: 'Back',
                      style: IconButton.styleFrom(backgroundColor: theme.colorScheme.surface),
                      onPressed: busy ? null : () => setState(() {
                        step--;
                        error = null;
                      }),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  if (step > 0) const SizedBox(width: 14),
                  Expanded(
                    child: Semantics(
                      label: 'Step ${step + 1} of $_steps',
                      child: Row(children: [
                        for (var i = 0; i < _steps; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          Expanded(
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: i <= step ? theme.colorScheme.onSurface : c.range,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ],
                      ]),
                    ),
                  ),
                ]),
                const SizedBox(height: 28),
                Expanded(child: ListView(children: [_body(theme, c)])),
                if (error != null)
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(error!, style: TextStyle(color: c.warn))),
                Text(_footnote, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                const SizedBox(height: 10),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: busy ? null : _next,
                  child: busy
                      ? BusyWords(lines: step == _steps - 1 ? onboardingWords : savingWords)
                      : Text(step == _steps - 1 ? 'See my first answer' : 'Continue'),
                ),
                if (step == 0)
                  TextButton(onPressed: () => context.read<AppState>().logOut(), child: const Text('Not you? Log out')),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  String get _footnote => switch (step) {
        0 => 'About two minutes. You can change any answer later under You.',
        5 => 'Next: your first answer, from the figures you gave.',
        _ => '${_steps - 1 - step} more question${_steps - 1 - step == 1 ? '' : 's'}, then your first answer.',
      };

  /// Every step says up front whether it has to be answered, so nobody wonders whether an empty box will block
  /// them (11 Nov).
  Widget _title(ThemeData theme, String step, String title, {String? help, _Need need = _Need.needed}) {
    final c = AppColors.of(context);
    final (bg, ink, words) = switch (need) {
      _Need.needed => (theme.colorScheme.onSurface, theme.colorScheme.surface, 'Needed'),
      _Need.optional => (c.lime, c.onLime, 'All optional — skip the lot'),
      _Need.some => (c.field, theme.colorScheme.onSurface, 'Only what applies to you'),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(step, style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Text(words,
              style: theme.textTheme.labelSmall?.copyWith(color: ink, fontWeight: FontWeight.w700)),
        ),
      ]),
      const SizedBox(height: 10),
      Text(title, style: theme.textTheme.headlineMedium?.copyWith(height: 1.2)),
      if (help != null) ...[
        const SizedBox(height: 10),
        Text(help, style: theme.textTheme.bodyLarge),
      ],
      const SizedBox(height: 24),
    ]);
  }

  Widget _yesNo(String question, bool? value, ValueChanged<bool> onChanged) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(question, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            showSelectedIcon: true,   // a tick on the chosen answer: a dark segment alone did not read as "chosen"
            emptySelectionAllowed: true,
            segments: const [ButtonSegment(value: true, label: Text('Yes')), ButtonSegment(value: false, label: Text('No'))],
            selected: {?value},
            onSelectionChanged: (s) {
              if (s.isNotEmpty) onChanged(s.first);
            },
          ),
        ],
      );

  Widget _money(TextEditingController ctl, String label,
          {bool big = false, String? hint, bool optional = false, String? helper}) =>
      TextField(
        controller: ctl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: big ? Theme.of(context).textTheme.headlineSmall : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixText: 'KES ',
          helperMaxLines: 2,
          helperText: helper ?? (optional ? 'Optional. Leave it empty if it does not apply.' : null),
        ),
      );

  Widget _body(ThemeData theme, AppColors c) {
    final who = first.isEmpty ? '' : ', $first';
    switch (step) {
      case 0:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(theme, 'Step 1 of $_steps', 'What should we call you?',
              help: 'A few quick questions, so Tosha\'s answers are about your household and not an average one. '
                  'Each one says whether you have to answer it.'),
          TextField(
            controller: name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            maxLength: 40,
            style: theme.textTheme.headlineSmall,
            decoration: const InputDecoration(labelText: 'First name', helperText: 'Needed'),
            onSubmitted: (_) => _next(),
          ),
          const InfoNote.why(text: 'Only so Tosha can greet you by name. It is never shown to anyone else.'),
        ]);
      case 1:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(theme, 'Step 2 of $_steps', 'How does money come in$who?',
              help: 'Pick all that apply. A tick shows what you picked. Tap again to take it off.'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in incomeTypeLabels.entries)
              FilterChip(
                label: Text(e.value),
                selected: types.contains(e.key),
                showCheckmark: true,   // 10 Nov: without the tick, testers could not tell picked from not picked
                onSelected: (on) => setState(() {
                  if (e.key == 'none' && on) types.clear();
                  if (e.key != 'none' && on) types.remove('none');
                  on ? types.add(e.key) : types.remove(e.key);
                }),
              ),
          ]),
          const InfoNote.why(
              text: 'A salary lands once a month. Casual work and business do not. Tosha plans your month around '
                  'the way your own money arrives.'),
          const SizedBox(height: 24),
          Panel(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Are you studying?'),
              subtitle: const Text('University, college or school'),
              value: studying,
              onChanged: (v) => setState(() => studying = v),
            ),
          ),
        ]);
      case 2:
        Widget counter(String label, String help, int value, int min, int max, ValueChanged<int> set) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: theme.textTheme.bodyLarge),
                    Text(help, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                  ]),
                ),
                IconButton.filledTonal(
                  tooltip: 'Fewer',
                  onPressed: value > min ? () => setState(() => set(value - 1)) : null,
                  icon: const Icon(Icons.remove_rounded),
                ),
                SizedBox(width: 44, child: Text('$value', textAlign: TextAlign.center, style: theme.textTheme.titleLarge)),
                IconButton.filledTonal(
                  tooltip: 'More',
                  onPressed: value < max ? () => setState(() => set(value + 1)) : null,
                  icon: const Icon(Icons.add_rounded),
                ),
              ]),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(theme, 'Step 3 of $_steps', 'Who lives with you?',
              help: 'Use the + and − buttons; 0 is a fine answer. The questions under them only show up if they '
                  'apply to you, and you can leave any of them unanswered.',
              need: _Need.some),
          Panel(
            child: Column(children: [
              counter('People at home, including you', 'Everyone who lives and eats with you.', people, 1, 20, (v) {
                people = v;
                support = support.clamp(0, v - 1);
                children = children.clamp(0, v - 1);
              }),
              counter('People at home who depend on your money', 'Those you pay for: children, a parent, a relative. '
                  'Not you. People who live elsewhere come next.', support, 0, people - 1, (v) => support = v),
              counter('Children in school', 'Only children whose school fees your household pays.', children, 0,
                  people - 1, (v) => children = v),
            ]),
          ),
          const InfoNote.why(
              text: 'A family of five needs more than one person living alone on the same money. This is how Tosha '
                  'judges your spending fairly, and how it sizes your budget. School fees land in some months and '
                  'not others, so it puts them in the right months.'),
          if (children > 0) ...[
            const SizedBox(height: 20),
            _yesNo('Do you pay their school fees?', paysChildFees, (v) => setState(() => paysChildFees = v)),
            if (paysChildFees == true) ...[
              const SizedBox(height: 12),
              _money(childFees, 'Fees per term, for all of them',
                  hint: '15,000', helper: 'Needed, since you pay them. A rough figure is fine.'),
            ],
          ],
          const SizedBox(height: 20),
          _yesNo('Do you send money to family or anyone else who lives elsewhere?', sendsMoney,
              (v) => setState(() => sendsMoney = v)),
          if (sendsMoney == true) ...[
            const SizedBox(height: 12),
            _money(sendHome, 'Roughly how much a month',
                hint: '3,000', helper: 'Needed, since you send money. A rough figure is fine.'),
          ],
          const InfoNote.why(
              text: 'Money you send leaves your account every month like any other bill, so Tosha sets it aside '
                  'before sharing out what is left.'),
          if (studying) ...[
            const SizedBox(height: 20),
            _yesNo('Do you pay your own fees?', paysOwnFees, (v) => setState(() => paysOwnFees = v)),
            if (paysOwnFees == false)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Parents, a sponsor or HELB pay them: they are left out of your budget.',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
              ),
            if (paysOwnFees == true) ...[
              const SizedBox(height: 12),
              _money(ownFees, 'Fees per semester', helper: 'Needed, since you pay them. A rough figure is fine.'),
            ],
          ],
        ]);
      case 3:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(theme, 'Step 4 of $_steps', 'How much comes in each month$who?',
              help: studying
                  ? 'Allowance, HELB upkeep, gigs, all together. A rough number is fine.'
                  : 'Salary, business, support from family, all together. A rough number is fine.'),
          _money(income, 'Money in, a usual month',
              big: true, helper: 'Needed. Type 0 if nothing comes in right now.'),
          const InfoNote.why(
              text: 'Everything Tosha tells you is measured against what comes in. A rough figure is fine; your '
                  'statement will correct it.'),
          const SizedBox(height: 20),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Does it change month to month?', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                showSelectedIcon: true,
                segments: const [
                  ButtonSegment(value: false, label: Text("It's steady")),
                  ButtonSegment(value: true, label: Text('It changes')),
                ],
                selected: {varies},
                onSelectionChanged: (s) => setState(() => varies = s.first),
              ),
              if (varies) ...[
                const SizedBox(height: 14),
                _money(low, 'A low month is about', optional: true),
                const InfoNote.why(
                    text: 'So Tosha never tells you something is affordable when it would only work in a good '
                        'month.'),
              ],
            ]),
          ),
        ]);
      case 4:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(theme, 'Step 5 of $_steps', 'Rent, and money you have saved',
              help: 'Neither is needed. Tosha just gets sharper if you have them.', need: _Need.optional),
          _money(rent, 'Rent per month', optional: true, hint: 'Leave empty if you do not pay rent'),
          const SizedBox(height: 24),
          _money(saved, 'Money you already have saved',
              optional: true, hint: 'M-Shwari, KCB M-PESA, SACCO, bank, cash'),
          const SizedBox(height: 10),
          const InfoNote.why(
              text: 'Rent is set aside before everyday money. Savings are how Tosha works out how long you could '
                  'cover a gap if a month went wrong. Put all your savings together, as they are today. You can '
                  'change both any time under You.'),
        ]);
      default:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(theme, 'Step 6 of $_steps', 'Roughly, what does a usual month cost?',
              help: 'Fill in what you know and leave the rest. You can press Continue with every box empty.',
              need: _Need.optional),
          const InfoNote.why(
              text: 'These let Tosha give you an answer today, before your statement is in. Once you add a '
                  'statement, your real records replace them.',
              margin: EdgeInsets.only(bottom: 18)),
          for (final k in _usualKeys) ...[
            _money(usual[k]!, spendingCategories[k]!, optional: true),
            const SizedBox(height: 18),
          ],
        ]);
    }
  }
}
