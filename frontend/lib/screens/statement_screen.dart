import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../widgets/busy_words.dart';
import '../widgets/panel.dart';
import 'payees_screen.dart' show TagChips;
import 'profile_screen.dart' show kes;

/// Bring in months of spending from an M-PESA statement: pick the PDF, check what was read, optionally say who
/// unclear payees are, confirm one-off purchases, then import. Nothing is saved before Import.
class StatementScreen extends StatefulWidget {
  const StatementScreen({super.key});

  @override
  State<StatementScreen> createState() => _StatementScreenState();
}

class _StatementScreenState extends State<StatementScreen> {
  final _password = TextEditingController();
  List<int>? bytes;
  String? filename;
  bool busy = false;
  String? error;
  Map<String, dynamic>? preview;
  final tags = <String, String>{};
  final oneOff = <int, bool>{};
  final goalsDone = <String>{};
  bool replaceManual = true;

  Api get api => context.read<AppState>().api;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    // file_picker 13: static pickFile(); bytes are read separately (withData was removed).
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['pdf']);
    if (f == null) return;
    final data = await f.readAsBytes();
    if (!mounted) return;
    setState(() {
      bytes = data;
      filename = f.name;
      error = null;
    });
  }

  Future<void> _read() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final p = await api.previewStatement(bytes!, filename ?? 'statement.pdf', _password.text.trim());
      setState(() {
        preview = p;
        for (final t in (p['transactions'] as List).cast<Map<String, dynamic>>()) {
          if (t['one_off'] == true) oneOff[t['n'] as int] = true;
        }
      });
    } on ApiException catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => busy = true);
    final txs = (preview!['transactions'] as List).cast<Map<String, dynamic>>().map((t) {
      final n = t['n'] as int;
      return {...t, 'one_off': oneOff[n] ?? false};
    }).toList();
    try {
      final r = await api.importStatement({
        'transactions': txs,
        'tags': tags,
        'period': preview!['period'],
        'completed_goals': goalsDone.toList(),
        'replace_manual': replaceManual,
      });
      if (!mounted) return;
      final notes = ((r['notes'] as List?) ?? []).cast<String>();
      await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: Text('Imported ${r['imported']} records'),
                content: Text(notes.isEmpty
                    ? 'Your dashboard, budget and forecast now use your statement.'
                    : notes.join('\n\n')),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
              ));
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _payee(Map<String, dynamic> p) {
    final theme = Theme.of(context);
    final s = p['suggestion'] as Map<String, dynamic>?;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text((p['payee'] ?? p['label']) as String, style: const TextStyle(fontWeight: FontWeight.w600))),
            Text(kes(p['total'] as num), style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          Text('${p['type_label']} · ${p['count']} payment(s) · sorted as: '
              '${p['direction'] == 'in' ? (inTagLabels[p['category']] ?? p['category']) : categoryLabel(p['category'] as String)}',
              style: theme.textTheme.bodySmall),
          // People remember when and how much, not account numbers.
          ...((p['recent'] as List?) ?? []).cast<Map<String, dynamic>>().map((pm) =>
              Text('• ${kes(pm['amount'] as num)} on ${pm['date']}', style: theme.textTheme.bodySmall)),
          ...[if (s != null) s['why'] as String, ...((p['hints'] as List?) ?? []).cast<String>()].map((h) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.lightbulb_outline, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                  Expanded(child: Text(h, style: theme.textTheme.bodySmall)),
                ]),
              )),
          const SizedBox(height: 8),
          TagChips(
            selected: tags[p['key']] ?? p['category'] as String?,   // the current category, highlighted
            suggested: s?['tag'] as String?,
            moneyIn: p['direction'] == 'in',
            onPick: (tag) => setState(() => tags[p['key'] as String] = tag),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = preview;
    return Scaffold(
      appBar: AppBar(title: const Text('M-PESA statement')),
      body: PageWidth(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (p == null) ...[
            Text('Bring in your spending from M-PESA', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Get a full statement from the M-PESA app or *334#. The file and its password are only used to '
                'read it and are never stored; you check everything before it is saved.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: busy ? null : _pick,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(filename ?? 'Choose statement (PDF)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Password (if the PDF is locked)', helperText: 'The code Safaricom sent you by SMS'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy || bytes == null ? null : _read,
              child: busy
                  ? const BusyWords(lines: statementWords)
                  : const Text('Read statement'),
            ),
          ] else ...[
            Card(
              color: theme.colorScheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.verified_outlined),
                title: Text('Read all ${p['checks']['rows']} transactions'),
                subtitle: Text('${(p['period'] as List?)?.join(' to ') ?? ''}. '
                    'Every total matches your statement, so nothing was missed.'),
              ),
            ),
            const SizedBox(height: 8),
            Text(p['new'] == 0
                ? 'Everything in this statement is already in the app.'
                : '${p['new']} spending payments are ready to import. Money moving between your own bank and '
                    'fund accounts is left out; what you put away counts as savings.'),
            if (((p['manual_overlap'] as Map?)?['count'] ?? 0) > 0)
              Card(
                margin: const EdgeInsets.only(top: 12),
                child: SwitchListTile(
                  value: replaceManual,
                  onChanged: (v) => setState(() => replaceManual = v),
                  title: Text('Replace my ${(p['manual_overlap'] as Map)['count']} hand-entered record(s) in '
                      '${((p['manual_overlap'] as Map)['months'] as List).join(', ')}'),
                  subtitle: const Text('Recommended, so nothing is counted twice. Turn off only if those records '
                      'were cash spending that M-PESA does not show.'),
                ),
              ),
            Card(
              margin: const EdgeInsets.only(top: 12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${((1 - (((p['coverage'] as Map)['unsorted'] ?? 0) as num)) * 100).round()}% of your spending '
                      'is already sorted', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text('Shops, bills and M-PESA types Tosha knows are sorted for you. Anything it is not sure about '
                      'stays "Not sorted yet": it still counts in your totals, and nothing is guessed.',
                      style: theme.textTheme.bodySmall),
                ]),
              ),
            ),
            ...() {
              final all = (p['payees'] as List).cast<Map<String, dynamic>>();
              final pay = all.where((x) => x['direction'] != 'in').toList();
              final paidBy = all.where((x) => x['direction'] == 'in').toList();
              return [
                if (pay.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Who you pay', style: theme.textTheme.titleMedium),
                  Text('Optional. The highlighted choice is what each one is now. Change it once and Tosha remembers '
                      'it for every statement. Skip any you do not recognise.', style: theme.textTheme.bodySmall),
                  ...pay.take(10).map(_payee),
                  if (pay.length > 10)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text('More (${pay.length - 10})'),
                      children: pay.skip(10).map(_payee).toList(),
                    ),
                ],
                if (paidBy.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Who pays you', style: theme.textTheme.titleMedium),
                  Text('Optional, but it makes your score real. Money from a bank could be your pay or allowance, '
                      'or your own money moving. If one source sends both (your salary and your own savings from '
                      'NCBA, say), change single payments later in Who you pay and who pays you.',
                      style: theme.textTheme.bodySmall),
                  ...paidBy.map(_payee),
                ],
              ];
            }(),
            ...() {
              final big = (p['transactions'] as List)
                  .cast<Map<String, dynamic>>()
                  .where((t) => t['one_off'] == true)
                  .toList();
              if (big.isEmpty) return <Widget>[];
              return [
                const SizedBox(height: 16),
                Text('Big one-off payments', style: theme.textTheme.titleMedium),
                Text('Much bigger than a usual month. Keeping them out of your usual spending stops one purchase '
                    'from distorting your budget and forecast.', style: theme.textTheme.bodySmall),
                ...big.map((t) {
                  final n = t['n'] as int;
                  final goals = (t['goals'] as List? ?? []).cast<Map<String, dynamic>>();
                  return Card(
                    margin: const EdgeInsets.only(top: 8),
                    child: Column(children: [
                      CheckboxListTile(
                        value: oneOff[n] ?? false,
                        onChanged: (v) => setState(() => oneOff[n] = v ?? false),
                        title: Text('${kes(t['amount'] as num)} on ${t['date']}'),
                        subtitle: Text('${t['label']}\nA one-off purchase (phone, laptop, furniture…)'),
                        isThreeLine: true,
                      ),
                      ...goals.map((g) => SwitchListTile(
                            value: goalsDone.contains(g['name']),
                            onChanged: (v) => setState(() =>
                                v ? goalsDone.add(g['name'] as String) : goalsDone.remove(g['name'])),
                            title: Text('This was my "${g['name']}" goal'),
                            subtitle: Text('Target ${kes(g['target'] as num)}, saved ${kes(g['saved'] as num)}. '
                                'Marks it done and stops setting money aside for it.'),
                          )),
                    ]),
                  );
                }),
              ];
            }(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: busy || p['new'] == 0 ? null : _import,
              icon: const Icon(Icons.download_done),
              label: const Text('Import'),
            ),
          ],
          if (p == null && error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      )),
    );
  }
}
