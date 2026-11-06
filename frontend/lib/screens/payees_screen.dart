import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../widgets/panel.dart';
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
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 4,
        children: (moneyIn ? inTagLabels : tagLabels).entries
            .where((e) => allowOwnAccount || e.key != 'own_account')
            .map((e) => ChoiceChip(
                  label: Text(e.key == suggested ? '${e.value} ?' : e.value),
                  selected: selected == e.key,
                  avatar: e.key == suggested && selected != e.key ? const Icon(Icons.lightbulb_outline, size: 16) : null,
                  onSelected: (_) => onPick(e.key),
                ))
            .toList(),
      );
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
    final shown = onlyToSort
        ? all
            .where((p) => p['tag'] == null && (p['category'] == 'unsorted' || p['type'] == 'sent' ||
                p['type'] == 'pochi' || p['direction'] == 'in'))
            .toList()
        : all;
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
          ? Center(child: error != null ? Text(error!) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Tell Tosha who people and businesses are, once. It applies to every past and future '
                      'payment.', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text('${((data!['sorted_share'] as num) * 100).round()}% of your statement money is sorted',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: (data!['sorted_share'] as num).toDouble(), minHeight: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: onlyToSort,
                    onChanged: (v) => setState(() => onlyToSort = v),
                    title: const Text('Only show who still needs sorting'),
                  ),
                  if (shown.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: Center(child: Text('Nothing left to sort. Upload a statement to add more.')),
                    ),
                  ...pay.map((p) => _PayeeCard(
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
                    ...paidBy.map((p) => _PayeeCard(
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

String _now(Map<String, dynamic> p, String? tag) {
  final c = tag ?? p['category'] as String;
  if (p['direction'] == 'in') return inTagLabels[c] ?? (c == 'own_account' ? inTagLabels['own_account']! : c);
  return tagLabels[c] ?? categoryLabel(c);
}

class _PayeeCard extends StatelessWidget {
  const _PayeeCard({required this.payee, required this.onTag, this.onUntag, this.onPayments});
  final Map<String, dynamic> payee;
  final void Function(String tag) onTag;
  final VoidCallback? onUntag;
  final VoidCallback? onPayments;   // money coming in: change one payment on its own

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = payee['suggestion'] as Map<String, dynamic>?;
    final tag = payee['tag'] as String?;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text((payee['payee'] ?? payee['label'] ?? '') as String,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Text(kes(payee['total'] as num), style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          Text('${payee['type_label'] ?? ''} · ${payee['count']} payment(s) · last ${payee['last']}'
              ' · sorted as: ${_now(payee, tag)}',
              style: theme.textTheme.bodySmall),
          if (s != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Icon(Icons.lightbulb_outline, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Expanded(child: Text(s['why'] as String, style: theme.textTheme.bodySmall)),
              ]),
            ),
          const SizedBox(height: 8),
          // The current category is highlighted, so you can see what it is and change it in one tap.
          TagChips(
            selected: tag ?? payee['category'] as String?,
            suggested: s?['tag'] as String?,
            moneyIn: payee['direction'] == 'in',
            onPick: onTag,
          ),
          Wrap(spacing: 4, children: [
            if (onPayments != null && (payee['count'] as num) > 1)
              TextButton(onPressed: onPayments, child: const Text('Change one payment')),
            if (onUntag != null)
              TextButton(onPressed: onUntag, child: const Text('Undo: back to how the statement sorted it')),
          ]),
        ]),
      ),
    );
  }
}
