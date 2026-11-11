import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/info_note.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/busy_words.dart';
import '../widgets/panel.dart';
import 'payees_screen.dart' show PayeeCard;
import 'profile_screen.dart' show kes;

/// Bring in months of spending from an M-PESA statement: pick the PDF, check what was read, optionally say who
/// unclear payees are, confirm one-off purchases, then import. Nothing is saved before Import.
class StatementScreen extends StatefulWidget {
  const StatementScreen({super.key, this.messages = false});
  /// Pasted M-PESA SMS instead of a PDF statement: keeps the figures current between statements.
  final bool messages;

  @override
  State<StatementScreen> createState() => _StatementScreenState();
}

class _StatementScreenState extends State<StatementScreen> {
  final _password = TextEditingController();
  final _text = TextEditingController();
  List<int>? bytes;
  String? filename;
  bool busy = false;
  String? error;
  Map<String, dynamic>? preview;
  final tags = <String, String>{};
  final oneOff = <int, bool>{};
  final goalsDone = <String>{};
  bool replaceManual = true;
  bool _showAll = false;

  Api get api => context.read<AppState>().api;

  @override
  void dispose() {
    _password.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    // file_picker 13: static pickFile(); bytes are read separately (withData was removed).
    // Any file type (10 Nov): on an iPhone, asking for ".pdf" only can grey out a real statement (from Mail or
    // Files), so the picker shows everything and Tosha checks the file itself.
    try {
      final f = await FilePicker.pickFile(type: FileType.any);
      if (f == null) return;
      final data = await f.readAsBytes();
      if (!mounted) return;
      final isPdf = data.length > 4 && String.fromCharCodes(data.take(5)) == '%PDF-';
      setState(() {
        if (!isPdf) {
          bytes = null;
          filename = null;
          error = 'That file is not a PDF. Choose the statement Safaricom emailed you. On an iPhone, open the email, '
              'tap the PDF, then Share, then Save to Files.';
          return;
        }
        bytes = data;
        filename = f.name;
        error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not open that file on this device. Save the statement PDF to your phone first '
            '(on an iPhone: open it in Mail, tap Share, then Save to Files), then choose it again.');
      }
    }
  }

  Future<void> _read() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final p = widget.messages
          ? await api.previewMessages(_text.text)
          : await api.previewStatement(bytes!, filename ?? 'statement.pdf', _password.text.trim());
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
        'origin': preview!['origin'] ?? 'statement',
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

  Widget _payee(Map<String, dynamic> p) => PayeeCard(
        payee: p,
        picked: tags[p['key']],
        onTag: (tag) => setState(() => tags[p['key'] as String] = tag),
      );

  Widget _pasteStep(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const PanelTitle('Paste your M-PESA messages', icon: Icons.sms_outlined),
          const SizedBox(height: 10),
          Text('Keeps your figures current between statements. In your messages app, press and hold an M-PESA '
              'confirmation, copy it, and paste it here. Paste as many as you like, one after another.',
              style: TextStyle(color: c.muted)),
        ]),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _text,
        minLines: 8,
        maxLines: 16,
        keyboardType: TextInputType.multiline,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'M-PESA messages',
          alignLabelWithHint: true,
          hintText: 'TK12AB3CD4 Confirmed. Ksh1,240.00 paid to NAIVAS…',
        ),
      ),
      if (error != null) _Problem(error!),
      const SizedBox(height: 18),
      FilledButton(
        style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(54), backgroundColor: c.lime, foregroundColor: c.onLime),
        onPressed: busy || _text.text.trim().isEmpty ? null : _read,
        child: busy
            ? const BusyWords(lines: ['Reading your messages…', 'Sorting shops and bills…', 'Skipping ones already in…'])
            : const Text('Read messages'),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Icon(Icons.lock_rounded, size: 16, color: c.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text('Only payments are kept, and only after you check them. Messages already in the app are '
              'skipped, so pasting one twice is safe.', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        ),
      ]),
    ]);
  }

  Widget _pickStep(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(radius: 12, backgroundColor: c.field,
                child: Text(n, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface))),
            const SizedBox(width: 12),
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(text))),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const PanelTitle('Bring in months of spending at once', icon: Icons.file_upload_outlined),
          const SizedBox(height: 10),
          Text('Tosha reads your M-PESA statement, checks every total and sorts what it is sure about.',
              style: TextStyle(color: c.muted)),
          const SizedBox(height: 18),
          step('1', 'Dial *334#, then My Account, M-PESA Statement, Request Statement. Choose a full statement for 12 '
              'months: a full year gives the most accurate answers.'),
          step('2', 'Safaricom emails you a PDF and texts you its password.'),
          step('3', 'Save the PDF to your phone (iPhone: open the email, tap the PDF, Share, Save to Files), then '
              'choose it here and type the password.'),
          const InfoNote(
            icon: Icons.lock_rounded,
            text: 'The file and its password are used to read it, then thrown away. You see everything before '
                'anything is saved.',
            margin: EdgeInsets.only(top: 14),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Material(
        color: bytes == null ? c.field : c.lime.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: busy ? null : _pick,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
            child: Column(children: [
              Icon(bytes == null ? Icons.upload_file_rounded : Icons.picture_as_pdf_rounded, size: 36,
                  color: theme.colorScheme.onSurface),
              const SizedBox(height: 8),
              Text(filename ?? 'Choose your statement (PDF)', textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(bytes == null ? 'Tap to pick the file' : 'Tap to choose a different file',
                  style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(
            labelText: 'Password (if the PDF is locked)',
            helperText: 'Safaricom locks the PDF. Tosha needs the code it texted you to open it, and never keeps it.',
            helperMaxLines: 3),
      ),
      if (error != null) _Problem(error!),
      const SizedBox(height: 18),
      FilledButton(
        style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(54), backgroundColor: c.lime, foregroundColor: c.onLime),
        onPressed: busy || bytes == null ? null : _read,
        child: busy ? const BusyWords(lines: statementWords) : const Text('Read statement'),
      ),
    ]);
  }

  Widget _reviewStep(BuildContext context, Map<String, dynamic> p) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final unsorted = (((p['coverage'] as Map)['unsorted'] ?? 0) as num).toDouble();
    final all = (p['payees'] as List).cast<Map<String, dynamic>>();
    final pay = all.where((x) => x['direction'] != 'in').toList();
    final paidBy = all.where((x) => x['direction'] == 'in').toList();
    final big = (p['transactions'] as List).cast<Map<String, dynamic>>().where((t) => t['one_off'] == true).toList();
    final overlap = (p['manual_overlap'] as Map?)?.cast<String, dynamic>();
    final fromMessages = p['origin'] == 'messages';
    final notRead = ((p['not_read'] as List?) ?? []).cast<Map<String, dynamic>>();
    Widget section(String title, String help) => Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(help, style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        color: c.lime,
        child: Row(children: [
          Icon(Icons.verified_rounded, color: c.onLime, size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(fromMessages ? 'Read ${p['checks']['rows']} payment message(s)' : 'All ${p['checks']['rows']} transactions read',
                  style: theme.textTheme.titleLarge?.copyWith(color: c.onLime)),
              Text(fromMessages
                  ? 'Check them below, then import. Anything you typed in by hand is kept.'
                  : '${(p['period'] as List?)?.join(' to ') ?? ''}. Every total matches your statement, so nothing '
                      'was missed.', style: TextStyle(color: c.onLime)),
            ]),
          ),
        ]),
      ),
      if (notRead.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${notRead.length} message(s) not read', style: TextStyle(color: c.warn, fontWeight: FontWeight.w700)),
            for (final m in notRead.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('"${m['message']}…": ${m['reason']}', style: TextStyle(color: c.warn)),
              ),
          ]),
        ),
      const SizedBox(height: 16),
      CardRow(minWidth: 200, children: [
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['new']}', style: theme.textTheme.headlineMedium),
            Text(p['new'] == 0 ? 'Everything is already in the app' : 'New payments to bring in',
                style: TextStyle(color: c.muted)),
          ]),
        ),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${((1 - unsorted) * 100).round()}%', style: theme.textTheme.headlineMedium),
            Text('of the money sorted already', style: TextStyle(color: c.muted)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: (1 - unsorted).clamp(0.0, 1.0), minHeight: 10,
                  color: c.lime, backgroundColor: c.range),
            ),
          ]),
        ),
      ]),
      const SizedBox(height: 10),
      Text('Shops, bills and M-PESA types Tosha knows are sorted for you. Anything it is not sure about stays '
          '"Not sorted yet": it still counts in your totals, and nothing is guessed. Money moving between your own '
          'accounts is left out; what you put away counts as savings.',
          style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
      if ((overlap?['count'] ?? 0) > 0)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Panel(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: replaceManual,
              onChanged: (v) => setState(() => replaceManual = v),
              title: Text('Replace my ${overlap!['count']} typed-in record(s) in ${(overlap['months'] as List).join(', ')}'),
              subtitle: const Text('Recommended, so nothing is counted twice. Turn off only if those were cash '
                  'payments M-PESA does not show.'),
            ),
          ),
        ),
      if (pay.isNotEmpty) ...[
        section('Who you pay', 'Optional. Each shows what it is now; suggestions are in lime. Change one once and '
            'Tosha remembers it for every statement. Skip any you do not recognise.'),
        ...pay.take(_showAll ? pay.length : 8).map(_payee),
        if (pay.length > 8 && !_showAll)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton.tonal(
                onPressed: () => setState(() => _showAll = true), child: Text('Show ${pay.length - 8} more')),
          ),
      ],
      if (paidBy.isNotEmpty) ...[
        section('Who pays you', 'Optional, but it makes your score real. Money from a bank could be your pay or '
            'allowance, or your own money moving. You can change single payments later in Who you pay.'),
        ...paidBy.map(_payee),
      ],
      if (big.isNotEmpty) ...[
        section('Big one-off payments', 'Much bigger than a usual month. Keeping them apart stops one purchase from '
            'bending your budget and forecast.'),
        for (final t in big) _oneOffCard(t),
      ],
      if (error != null) _Problem(error!),
      const SizedBox(height: 24),
    ]);
  }

  Widget _oneOffCard(Map<String, dynamic> t) {
    final n = t['n'] as int;
    final goals = (t['goals'] as List? ?? []).cast<Map<String, dynamic>>();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
                onChanged: (v) => setState(() => v ? goalsDone.add(g['name'] as String) : goalsDone.remove(g['name'])),
                title: Text('This was my "${g['name']}" goal'),
                subtitle: Text('Target ${kes(g['target'] as num)}, saved ${kes(g['saved'] as num)}. '
                    'Marks it done and stops setting money aside for it.'),
              )),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final p = preview;
    return Scaffold(
      appBar: AppBar(title: Text(p == null ? (widget.messages ? 'M-PESA messages' : 'M-PESA statement') : 'Check before you import')),
      body: PageWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [p == null ? (widget.messages ? _pasteStep(context) : _pickStep(context)) : _reviewStep(context, p)],
        ),
      ),
      bottomNavigationBar: p == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Align(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54), backgroundColor: c.lime, foregroundColor: c.onLime),
                    onPressed: busy || p['new'] == 0 ? null : _import,
                    child: busy
                        ? const BusyWords(lines: ['Saving your records…', 'Working out your figures again…'])
                        : Text(p['new'] == 0 ? 'Nothing new to import' : 'Import ${p['new']} payments'),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(14)),
      child: Text(text, style: TextStyle(color: c.warn)),
    );
  }
}
