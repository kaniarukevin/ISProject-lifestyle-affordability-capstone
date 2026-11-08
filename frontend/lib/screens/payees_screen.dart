import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/panel.dart';
import '../widgets/busy_words.dart';
import 'profile_screen.dart' show kes;

/// One-tap choices for what a payee or payment is. [selected] is highlighted; [suggested] gets a hint mark.
class TagChips extends StatelessWidget {
  const TagChips({super.key, required this.onPick, this.selected, this.suggested, this.allowOwnAccount = true,
      this.moneyIn = false});
  final void Function(String tag) onPick;
  final String? selected, suggested;
  final bool allowOwnAccount;

  /// Money coming in: pay, a mix, own money, someone paying back (instead of spending categories).
  final bool moneyIn;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: (moneyIn ? inTagLabels : tagLabels).entries
          .where((e) => allowOwnAccount || e.key != 'own_account')
          .map((e) {
        final hint = e.key == suggested && selected != e.key;
        return ChoiceChip(
          label: Text(e.value),
          selected: selected == e.key,
          showCheckmark: false,
          // The suggestion wears a touch of lime, so the likely answer is one tap away and easy to spot.
          backgroundColor: hint ? c.lime.withValues(alpha: 0.55) : null,
          side: hint ? BorderSide(color: c.lime, width: 1.5) : null,
          avatar: hint ? Icon(Icons.auto_awesome_rounded, size: 16, color: c.onLime) : null,
          labelStyle: hint ? TextStyle(color: c.onLime, fontWeight: FontWeight.w600) : null,
          tooltip: hint ? 'Suggested' : null,
          onSelected: (_) => onPick(e.key),
        );
      }).toList(),
    );
  }
}

/// A suggestion for an unknown payee ("same amount early each month: rent?"): a soft lime box with the reason
/// and a one-tap "Use it". Never applied without the user.
class SuggestionBox extends StatelessWidget {
  const SuggestionBox({super.key, required this.lines, this.label, this.onUse});
  final List<String> lines;
  final String? label;          // what the suggestion is, e.g. "Rent"
  final VoidCallback? onUse;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: c.lime.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.16 : 0.32),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Icon(Icons.auto_awesome_rounded, size: 18, color: Theme.of(context).colorScheme.onSurface),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final l in lines) Text(l),
          ]),
        ),
        if (onUse != null && label != null)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.lime, foregroundColor: c.onLime,
                minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
            onPressed: onUse,
            child: Text('Use: $label'),
          ),
      ]),
    );
  }
}

/// After tagging rent or school fees: offer to add it to commitments, so the budget sets it aside first.
Future<void> handleOffer(BuildContext context, Map<String, dynamic>? offer) async {
  if (offer == null) return;
  final api = context.read<AppState>().api;
  final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('Add to your commitments?'),
            content: Text(offer['text'] as String),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add it')),
            ],
          ));
  if (yes != true) return;
  try {
    await api.acceptCommitmentOffer(offer);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Added. Your budget now sets it aside first.')));
    }
  } on ApiException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Tap a payment to correct it: choose what it is, and whether that applies to just this payment or always
/// to this payee (past and future). Returns true when something changed.
const _oneOffSwitch = '__one_off__';

Future<bool> showCorrectSheet(BuildContext context, Txn t) async {
  final api = context.read<AppState>().api;
  var always = t.payeeKey != null;
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.title, style: Theme.of(ctx).textTheme.titleMedium),
          if (t.source == 'mpesa' && t.description.isNotEmpty)
            Text('On your statement: ${t.description}', style: Theme.of(ctx).textTheme.bodySmall),
          Text('${kes(t.amount)} · ${t.date.day}/${t.date.month}/${t.date.year}'
              '${t.type != null ? ' · ${mpesaTypes[t.type] ?? t.type}' : ''}'
              ' · now: ${categoryLabel(t.category)}'),
          const SizedBox(height: 12),
          Text('What is it?', style: Theme.of(ctx).textTheme.titleSmall),
          const SizedBox(height: 6),
          TagChips(
            selected: t.category,
            allowOwnAccount: t.payeeKey != null,
            onPick: (tag) => Navigator.pop(ctx, tag),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: t.oneOff,
            onChanged: (_) => Navigator.pop(ctx, _oneOffSwitch),
            title: const Text('One-off purchase'),
            subtitle: const Text('Big and rare, like a phone or a plot: shown, but kept out of your usual spending.'),
          ),
          if (t.payeeKey != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: always,
              onChanged: (v) => setSheet(() => always = v),
              title: Text('Always for ${t.payee ?? 'this payee'}'),
              subtitle: const Text('Past and future payments to them. Turn off to change just this one.'),
            ),
        ]),
      ),
    ),
  );
  if (picked == null || picked == t.category || !context.mounted) return false;
  if (picked == _oneOffSwitch) {
    try {
      await api.editTransaction(t.id!, {'one_off': !t.oneOff});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(t.oneOff ? 'Counted as usual spending again.' : 'Marked as a one-off.')));
      }
      return true;
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return false;
    }
  }
  try {
    final r = await api.correctTransaction(t.id!, picked, scope: always && t.payeeKey != null ? 'payee' : 'one');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['updated'] == 1 ? 'Changed.' : 'Changed ${r['updated']} payments to ${t.payee}.')));
      await handleOffer(context, r['offer'] as Map<String, dynamic>?);
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
}

/// "Who you pay": every person and business from your statements. Teach the app once (your landlord, your
/// mama mboga, your chama) and it applies to every past and future payment. Nothing is guessed.
class PayeesScreen extends StatefulWidget {
  const PayeesScreen({super.key});

  @override
  State<PayeesScreen> createState() => _PayeesScreenState();
}

class _PayeesScreenState extends State<PayeesScreen> {
  Map<String, dynamic>? data;
  String? error;
  bool onlyToSort = true;

  Api get api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.payees();
      setState(() {
        data = d;
        error = null;
      });
    } on ApiException catch (e) {
      setState(() => error = e.message);
    }
  }

  Future<void> _tag(Map<String, dynamic> p, String tag) async {
    try {
      final r = await api.tagPayee(p['key'] as String, tag);
      await _load();
      if (mounted) await handleOffer(context, r['offer'] as Map<String, dynamic>?);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// This payment only: list a source's payments coming in and change one (salary and own money from one bank).
  Future<void> _payments(Map<String, dynamic> p) async {
    List<Map<String, dynamic>> list;
    try {
      list = await api.moneyIn(p['key'] as String);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text((p['payee'] ?? 'Payments') as String, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Tap a payment to say what it was. The rest keep the source\'s tag.',
                style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: 8),
            for (final m in list)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${kes(m['amount'] as num)} on ${m['date']}'),
                subtitle: Text('${inTagLabels[m['kind']] ?? m['kind']}${m['pinned'] == true ? ' · changed on its own' : ''}'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final kind = await showModalBottomSheet<String>(
                    context: ctx,
                    builder: (c2) => Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${kes(m['amount'] as num)} on ${m['date']} was…', style: Theme.of(c2).textTheme.titleMedium),
                        const SizedBox(height: 10),
                        TagChips(moneyIn: true, selected: m['kind'] as String?, onPick: (k) => Navigator.pop(c2, k)),
                      ]),
                    ),
                  );
                  if (kind == null || kind == m['kind']) return;
                  try {
                    await api.changeMoneyIn(m['id'] as int, kind);
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } on ApiException catch (e) {
                    if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.message)));
                  }
                },
              ),
          ],
        ),
      ),
    );
    if (changed == true) {
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Changed that payment only.')));
    }
  }

  Future<void> _untag(Map<String, dynamic> p) async {
    await api.untagPayee(p['key'] as String);
    await _load();
  }

  Future<void> _undoImports() async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Remove imported statements?'),
              content: const Text('Deletes every record that came from M-PESA statements, so you can import again '
                  'cleanly. Your hand-entered records and your payee tags are kept.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
              ],
            ));
    if (yes != true) return;
    final n = await api.undoStatements();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Removed $n records.')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = ((data?['payees'] as List?) ?? []).cast<Map<String, dynamic>>();
    final shown = onlyToSort ? all.where(_toSort).toList() : all;
    final pay = shown.where((p) => p['direction'] != 'in').toList();
    final paidBy = shown.where((p) => p['direction'] == 'in').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Who you pay and who pays you'), actions: [
        PopupMenuButton<String>(
          onSelected: (_) => _undoImports(),
          itemBuilder: (_) => [const PopupMenuItem(value: 'undo', child: Text('Remove imported statements'))],
        ),
      ]),
      body: PageWidth(child: data == null
          ? (error != null ? Center(child: Text(error!)) : const BusyCenter(payeeWords))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Panel(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('${((data!['sorted_share'] as num) * 100).round()}% of your statement money is sorted',
                          style: theme.textTheme.titleLarge),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: LinearProgressIndicator(
                            value: (data!['sorted_share'] as num).toDouble(), minHeight: 14,
                            color: AppColors.of(context).lime, backgroundColor: AppColors.of(context).range),
                      ),
                      const SizedBox(height: 10),
                      Text('Tell Tosha who people and businesses are, once. It applies to every past and future '
                          'payment. Suggestions are marked in lime; nothing is changed without you.',
                          style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.of(context).muted)),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(value: true, label: Text('Still to sort (${all.where(_toSort).length})')),
                            ButtonSegment(value: false, label: Text('Everyone (${all.length})')),
                          ],
                          selected: {onlyToSort},
                          onSelectionChanged: (v) => setState(() => onlyToSort = v.first),
                        ),
                      ),
                    ]),
                  ),
                  if (shown.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: Center(child: Text('Nothing left to sort. Upload a statement to add more.')),
                    ),
                  ...pay.map((p) => PayeeCard(
                        payee: p,
                        onTag: (tag) => _tag(p, tag),
                        onUntag: p['tag'] == null ? null : () => _untag(p),
                      )),
                  if (paidBy.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text('Who pays you', style: theme.textTheme.titleMedium),
                    Text('Money from a bank could be your pay or allowance, or your own money moving. If your '
                        'allowance or salary is paid into your bank and you then move it to M-PESA, choose "My bank". '
                        'It counts up to your usual income, so moving savings never inflates it. Money from family '
                        'or friends for something specific is "Paid back or a gift". Church, chama and harambee count '
                        'under "Family, friends and giving".',
                        style: theme.textTheme.bodySmall),
                    ...paidBy.map((p) => PayeeCard(
                          payee: p,
                          onTag: (tag) => _tag(p, tag),
                          onUntag: p['tag'] == null ? null : () => _untag(p),
                          onPayments: () => _payments(p),
                        )),
                  ],
                ],
              ),
            )),
    );
  }
}

/// Still worth asking about: not tagged yet, and either unsorted, a person (sent, Pochi) or money coming in.
bool _toSort(Map<String, dynamic> p) =>
    p['tag'] == null &&
    (p['category'] == 'unsorted' || p['type'] == 'sent' || p['type'] == 'pochi' || p['direction'] == 'in');

String _now(Map<String, dynamic> p, String? tag) {
  final c = tag ?? p['category'] as String;
  if (p['direction'] == 'in') return inTagLabels[c] ?? (c == 'own_account' ? inTagLabels['own_account']! : c);
  return tagLabels[c] ?? categoryLabel(c);
}

/// One person or business: who, how much and how often, the recent payments people remember, a suggestion
/// if there is one, and one-tap choices. Used in Who you pay and while importing a statement.
class PayeeCard extends StatelessWidget {
  const PayeeCard({super.key, required this.payee, required this.onTag, this.onUntag, this.onPayments, this.picked});
  final Map<String, dynamic> payee;
  final void Function(String tag) onTag;
  final VoidCallback? onUntag;
  final VoidCallback? onPayments;   // money coming in: change one payment on its own
  final String? picked;             // a choice made on this screen but not saved yet (statement import)

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final s = payee['suggestion'] as Map<String, dynamic>?;
    final tag = picked ?? payee['tag'] as String?;
    final name = (payee['payee'] ?? payee['label'] ?? '') as String;
    final moneyIn = payee['direction'] == 'in';
    final hints = [if (s != null) s['why'] as String, ...((payee['hints'] as List?) ?? []).cast<String>()];
    final sTag = s?['tag'] as String?;
    final current = tag ?? payee['category'] as String?;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Panel(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: c.field,
              child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                  style: TextStyle(fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('${payee['type_label'] ?? ''} · ${payee['count']} payment${payee['count'] == 1 ? '' : 's'}'
                    '${payee['last'] != null ? ' · last ${payee['last']}' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
              ]),
            ),
            Text(kes(payee['total'] as num), style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          // People remember when and how much, not account numbers.
          for (final pm in ((payee['recent'] as List?) ?? []).cast<Map<String, dynamic>>())
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 52),
              child: Text('${kes(pm['amount'] as num)} on ${pm['date']}',
                  style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            ),
          const SizedBox(height: 8),
          Text('Now: ${_now(payee, tag)}', style: theme.textTheme.bodyMedium),
          if (hints.isNotEmpty)
            SuggestionBox(
              lines: hints,
              label: sTag == null || sTag == current
                  ? null
                  : (moneyIn ? inTagLabels[sTag] : tagLabels[sTag] ?? categoryLabel(sTag)),
              onUse: sTag == null || sTag == current ? null : () => onTag(sTag),
            ),
          const SizedBox(height: 12),
          // The current category is highlighted, so you can see what it is and change it in one tap.
          TagChips(selected: current, suggested: sTag, moneyIn: moneyIn, onPick: onTag),
          if ((onPayments != null && (payee['count'] as num) > 1) || onUntag != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 4, children: [
                if (onPayments != null && (payee['count'] as num) > 1)
                  TextButton(onPressed: onPayments, child: const Text('Change one payment')),
                if (onUntag != null)
                  TextButton(onPressed: onUntag, child: const Text('Undo: back to how the statement sorted it')),
              ]),
            ),
        ]),
      ),
    );
  }
}
