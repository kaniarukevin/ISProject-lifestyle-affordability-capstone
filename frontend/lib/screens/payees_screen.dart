import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../services/api.dart';
import '../state/app_state.dart';
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
      appBar: AppBar(title: const Text('Who you pay'), actions: [
        PopupMenuButton<String>(
          onSelected: (_) => _undoImports(),
          itemBuilder: (_) => [const PopupMenuItem(value: 'undo', child: Text('Remove imported statements'))],
        ),
      ]),
      body: data == null
          ? Center(child: error != null ? Text(error!) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Tell the app who people and businesses are, once. It applies to every past and future '
                      'payment to them.', style: theme.textTheme.bodySmall),
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
                    Text('A bank transfer to your M-PESA could be your allowance or salary, or your own savings. '
                        'Tell the app once; your score then uses the money that actually arrived.',
                        style: theme.textTheme.bodySmall),
                    ...paidBy.map((p) => _PayeeCard(
                          payee: p,
                          onTag: (tag) => _tag(p, tag),
                          onUntag: p['tag'] == null ? null : () => _untag(p),
                        )),
                  ],
                ],
              ),
            ),
    );
  }
}

String _now(Map<String, dynamic> p, String? tag) {
  final c = tag ?? p['category'] as String;
  if (p['direction'] == 'in') return inTagLabels[c] ?? (c == 'own_account' ? inTagLabels['own_account']! : c);
  return tagLabels[c] ?? categoryLabel(c);
}

class _PayeeCard extends StatelessWidget {
  const _PayeeCard({required this.payee, required this.onTag, this.onUntag});
  final Map<String, dynamic> payee;
  final void Function(String tag) onTag;
  final VoidCallback? onUntag;

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
              ' · now: ${_now(payee, tag)}',
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
          if (onUntag != null)
            TextButton(onPressed: onUntag, child: const Text('Undo: go back to how the statement sorted it')),
        ]),
      ),
    );
  }
}
