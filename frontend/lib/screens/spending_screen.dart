import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/state_words.dart';
import '../models/transaction.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../state/reload_on_change.dart';
import '../theme/app_theme.dart';
import '../widgets/busy_words.dart';
import '../widgets/charts.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/format.dart';
import '../widgets/money_in.dart';
import '../widgets/panel.dart';
import 'payees_screen.dart';
import 'statement_screen.dart';

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
  'October', 'November', 'December'];

String _key(int y, int m) => '$y-${m.toString().padLeft(2, '0')}';

/// Records opened on top of another screen (from You or the Add sheet).
class SpendingScreen extends StatelessWidget {
  const SpendingScreen({super.key, this.month});
  final String? month;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your records')),
        body: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: RecordsView(month: month))),
      );
}

/// What the household actually spends, one month at a time: the month in numbers, where the money went, and
/// every record. The rest of the app builds on these. Opens inside the tab you are on.
class RecordsView extends StatefulWidget {
  const RecordsView({super.key, this.month});
  final String? month;            // 'YYYY-MM' to open on; default the newest month with records

  @override
  State<RecordsView> createState() => _RecordsViewState();
}

class _RecordsViewState extends State<RecordsView> with ReloadOnChange {
  List<Map<String, dynamic>>? months;    // one summary line per month, newest first
  bool hasStatement = false;
  String? month;                         // the month on screen
  final Map<String, List<Txn>> _txs = {};  // months already fetched (shown at once when you come back)
  List<Map<String, dynamic>> _timeline = const [];   // state and score per month, from the last overview
  String _filter = 'all';
  String? error;
  bool _loading = false;
  final _search = TextEditingController();
  String _query = '';
  Future<List<Txn>>? _all;
  Future<List<Txn>>? _found;

  Api get api => context.read<AppState>().api;

  @override
  Future<void> reloadQuietly() => _load(month);

  @override
  void initState() {
    super.initState();
    month = widget.month;
    _showLast();
    _load(month);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The records from last time and the overview's month-by-month states, at once.
  Future<void> _showLast() async {
    final state = context.read<AppState>();
    final last = await state.cached('records');
    final o = await state.cached('overview');
    if (!mounted) return;
    setState(() {
      _timeline = ((o?['timeline'] as List?) ?? const []).cast<Map<String, dynamic>>();
      if (last != null && months == null && (widget.month == null || widget.month == last['month'])) _take(last);
    });
  }

  void _take(Map<String, dynamic> d) {
    months = ((d['months'] as List?) ?? []).cast<Map<String, dynamic>>();
    hasStatement = d['has_statement'] == true;
    month = d['month'] as String?;
    _txs[month!] = ((d['transactions'] as List?) ?? []).map((e) => Txn.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _load(String? m) async {
    setState(() => _loading = true);
    try {
      final d = await api.records(month: m);
      if (!mounted) return;
      setState(() {
        _take(d);
        error = null;
        _all = null;
      });
      final keys = _monthKeys;
      if (m == null || (keys.isNotEmpty && m == keys.first)) context.read<AppState>().keep('records', d);
      _prefetchNeighbours();
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The month before (and after) the one on screen, quietly, so the arrows feel instant.
  Future<void> _prefetchNeighbours() async {
    final keys = _monthKeys;
    final i = keys.indexOf(month ?? '');
    for (final j in [i + 1, i - 1]) {
      if (j < 0 || j >= keys.length || _txs.containsKey(keys[j])) continue;
      try {
        final d = await api.records(month: keys[j]);
        if (mounted) {
          _txs[keys[j]] = ((d['transactions'] as List?) ?? []).map((e) => Txn.fromJson(e as Map<String, dynamic>)).toList();
        }
      } catch (_) {/* only a head start */}
    }
  }

  List<String> get _monthKeys => [for (final m in months ?? const []) _key(m['year'] as int, m['month'] as int)];

  void _go(String key) {
    setState(() {
      month = key;
      _filter = 'all';
    });
    _load(key);
  }

  Future<void> _add() async {
    final t = await showDialog<Txn>(context: context, builder: (_) => const _AddTxnDialog());
    if (t == null) return;
    try {
      await api.addTransactions([t]);        // the screen reloads by itself after a change
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _edit(Txn t) async {
    final changed = await showDialog<Txn>(context: context, builder: (_) => _AddTxnDialog(initial: t));
    if (changed == null) return;
    try {
      await api.editTransaction(t.id!, {'amount': changed.amount, 'date': changed.isoDate,
          'description': changed.description, 'category': changed.category, 'one_off': changed.oneOff});
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Gone from the list at once; put back, with the reason, if the server refuses.
  Future<void> _delete(Txn t) async {
    final list = _txs[month];
    final at = list?.indexOf(t) ?? -1;
    if (at >= 0) setState(() => list!.removeAt(at));
    try {
      await api.deleteTransaction(t.id!);
    } on ApiException catch (e) {
      if (at >= 0 && mounted) setState(() => list!.insert(at, t));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _open(Txn t) async {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final what = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(kesAmount(t.amount), style: theme.textTheme.headlineMedium),
            const SizedBox(height: 12),
            _Fact('Date', '${t.date.day} ${_monthNames[t.date.month - 1]} ${t.date.year}'),
            _Fact('What it is', categoryLabel(t.category) + (t.oneOff ? ' · one-off' : '')),
            _Fact('Came from', t.source == 'mpesa' ? 'M-PESA statement' : (t.source == 'messages' ? 'M-PESA messages' : 'Typed in')),
            if (t.description.isNotEmpty && t.description != t.title)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(t.source == 'mpesa' ? 'On your statement: ${t.description}' : t.description,
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
              ),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'change'), child: const Text('Change what it is')),
            const SizedBox(height: 8),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.warn),
              onPressed: () => Navigator.pop(ctx, 'delete'),
              child: const Text('Delete this record'),
            ),
          ]),
        ),
      ),
    );
    if (!mounted) return;
    if (what == 'change') {
      if (t.source == 'mpesa') {
        await showCorrectSheet(context, t);
      } else {
        await _edit(t);
      }
    } else if (what == 'delete') {
      final yes = await showChoiceSheet<bool>(context,
          title: 'Delete this record?',
          message: '${t.title}, ${kesAmount(t.amount)}. Your figures will be worked out again without it.',
          choices: const [SheetChoice('Delete', true, primary: true)]);
      if (yes == true) await _delete(t);
    }
  }

  Future<List<Txn>> _matches() async {
    final all = await (_all ??= api.getTransactions());
    final q = _query.toLowerCase().replaceAll(',', '').trim();
    return all.where((t) {
      final text = '${t.title} ${t.payee ?? ''} ${t.description} ${categoryLabel(t.category)}'.toLowerCase();
      return text.contains(q) || t.amount.round().toString().contains(q);
    }).take(200).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    if (months == null) {
      return error != null ? Center(child: Text(error!, textAlign: TextAlign.center)) : const BusyCenter(recordsWords);
    }
    final keys = _monthKeys;
    final i = keys.indexOf(month ?? '');
    final summary = i >= 0 ? months![i] : null;
    final txs = _txs[month];
    final unsorted = (txs ?? const <Txn>[]).where((t) => t.category == 'unsorted').length;
    final cats = <String>{for (final t in txs ?? const <Txn>[]) t.category}.toList()
      ..sort((a, b) => categoryLabel(a).compareTo(categoryLabel(b)));
    final shown = (txs ?? const <Txn>[]).where((t) => _filter == 'all' || t.category == _filter).toList();

    final actions = Wrap(spacing: 8, runSpacing: 8, children: [
      FilledButton.icon(onPressed: _add, icon: const Icon(Icons.edit_rounded), label: const Text('Type spending')),
      FilledButton.tonalIcon(
        icon: const Icon(Icons.upload_file_rounded),
        label: const Text('Upload M-PESA statement'),
        onPressed: () async {
          await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const StatementScreen()));
        },
      ),
      FilledButton.tonalIcon(
        icon: const Icon(Icons.sms_rounded),
        label: const Text('Paste M-PESA messages'),
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const StatementScreen(messages: true))),
      ),
      if (hasStatement)
        FilledButton.tonalIcon(
          icon: const Icon(Icons.people_rounded),
          label: const Text('Who you pay'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PayeesScreen())),
        ),
    ]);

    return RefreshIndicator(
      onRefresh: () => _load(month),
      child: ListView(
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search: Naivas, rent, 1,240…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
            ),
            onChanged: (v) => setState(() {
              _query = v;
              _found = v.trim().isEmpty ? null : _matches();
            }),
          ),
          const SizedBox(height: 16),
          if (_query.trim().isNotEmpty)
            FutureBuilder<List<Txn>>(
              future: _found,
              builder: (context, snap) {
                if (snap.hasError) return const Text('Could not search. Pull down to try again.');
                if (!snap.hasData) return const BusyCenter(['Searching your records…']);
                final found = snap.data!;
                return Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(found.isEmpty ? 'Nothing matches "$_query".'
                        : '${found.length}${found.length == 200 ? '+' : ''} found · ${kesAmount(found.fold<double>(0, (a, t) => a + t.amount))}',
                        style: theme.textTheme.titleMedium),
                    for (final t in found) _Row(t: t, withYear: true, onTap: () => _open(t)),
                  ]),
                );
              },
            )
          else if (months!.isEmpty) ...[
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('No records yet', style: theme.textTheme.titleLarge),
                const SizedBox(height: 6),
                Text('Upload an M-PESA statement to bring in months at once, or type in what you spend.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
                const SizedBox(height: 16),
                actions,
              ]),
            ),
          ] else ...[
            Row(children: [
              IconButton.filledTonal(
                tooltip: 'Earlier month',
                onPressed: i < keys.length - 1 ? () => _go(keys[i + 1]) : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(summary == null ? '' : '${_monthNames[(summary['month'] as int) - 1]} ${summary['year']}',
                    textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
              ),
              IconButton.filledTonal(
                tooltip: 'Later month',
                onPressed: i > 0 ? () => _go(keys[i - 1]) : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ]),
            SizedBox(height: 3, child: _loading ? const LinearProgressIndicator() : null),
            const SizedBox(height: 12),
            if (summary != null) _MonthSummary(summary: summary, timeline: _timeline),
            const SizedBox(height: 20),
            if (unsorted > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Material(
                  color: c.lime,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => setState(() => _filter = 'unsorted'),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Icon(Icons.help_rounded, color: c.onLime),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('$unsorted payment${unsorted == 1 ? ' is' : 's are'} not sorted yet, so this month\'s '
                              'split may be off. Tap to sort ${unsorted == 1 ? 'it' : 'them'}.',
                              style: TextStyle(color: c.onLime, fontWeight: FontWeight.w600)),
                        ),
                        Icon(Icons.chevron_right_rounded, color: c.onLime),
                      ]),
                    ),
                  ),
                ),
              ),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('Every record', style: theme.textTheme.titleLarge)),
                  Text('${shown.length} of ${txs?.length ?? 0}', style: TextStyle(color: c.muted)),
                ]),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final f in ['all', ...cats])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(f == 'all' ? 'All' : categoryLabel(f)),
                          selected: _filter == f,
                          showCheckmark: false,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 8),
                if (txs == null)
                  const BusyCenter(monthWords)
                else if (shown.isEmpty)
                  Padding(padding: const EdgeInsets.all(16), child: Text('Nothing here.', style: TextStyle(color: c.muted)))
                else
                  for (final t in shown) _Row(t: t, onTap: () => _open(t)),
              ]),
            ),
            const SizedBox(height: 20),
            actions,
          ],
        ],
      ),
    );
  }
}

/// The month in numbers: spent, and (for months the overview scored) money in, saved, the state and score,
/// then where the money went.
class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.summary, required this.timeline});
  final Map<String, dynamic> summary;
  final List<Map<String, dynamic>> timeline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final scored = timeline.where((x) => x['year'] == summary['year'] && x['month'] == summary['month']).firstOrNull;
    final by = ((summary['by_category'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, (v as num)));
    final spent = (summary['total'] as num).toDouble();
    final oneOff = (summary['one_off'] as num?)?.toDouble() ?? 0;
    final state = scored?['state'] as String?;
    Widget figure(String value, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: theme.textTheme.titleLarge),
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        ]);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 28, runSpacing: 14, crossAxisAlignment: WrapCrossAlignment.center, children: [
          figure(kesAmount(spent), 'Spent'),
          if (scored != null)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => editMonthIncome(context, summary['year'] as int, summary['month'] as int,
                  scored['income'] as num, setByYou: scored['income_from'] == 'you'),
              child: figure(kesAmount(scored['income'] as num),
                  scored['income_from'] == 'you' ? 'Money in · set by you · change' : 'Money in · change'),
            ),
          if (scored != null) figure(kesAmount(scored['saved'] as num), 'Saved'),
          if (oneOff > 0) figure(kesAmount(oneOff), 'One-off, kept apart'),
          if (state != null) StateBadge(state: state, score: scored!['score'] as int),
          if (state == null)
            Text('This month is still going, so it has no score yet. You will see one when it ends.',
                style: TextStyle(color: c.muted)),
        ]),
        if (by.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Where the money went', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          DonutWithLegend(slices: categorySlices(context, by), centerLabel: 'KES spent'),
        ],
      ]),
    );
  }
}

/// A month's financial state as a small badge: its colour, its word and its score (never colour alone).
class StateBadge extends StatelessWidget {
  const StateBadge({super.key, required this.state, required this.score});
  final String state;
  final int score;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final bg = switch (state) { 'Stable' => c.stable, 'Strained' => c.strained, _ => c.critical };
    final fg = state == 'Critical' && Theme.of(context).brightness == Brightness.light ? Colors.white : const Color(0xFF111111);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text('${stateLabel(state)} · ${scoreOutOf(score)}', style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 110, child: Text(label, style: TextStyle(color: AppColors.of(context).muted))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

/// One record: a round category mark, a readable name, the date and category, the amount.
class _Row extends StatelessWidget {
  const _Row({required this.t, required this.onTap, this.withYear = false});
  final Txn t;
  final VoidCallback onTap;
  final bool withYear;

  static const _icons = {
    'food_groceries': Icons.shopping_basket_rounded, 'transport': Icons.directions_bus_rounded,
    'airtime_data': Icons.phone_android_rounded, 'utilities': Icons.bolt_rounded,
    'mobile_money_transfers': Icons.people_rounded, 'entertainment': Icons.celebration_rounded,
    'housing': Icons.home_rounded, 'school_fees': Icons.school_rounded, 'loan_repayment': Icons.account_balance_rounded,
    'savings': Icons.savings_rounded, 'charges': Icons.receipt_rounded, 'unsorted': Icons.help_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final color = ChartColors.category(context, t.category);
    final date = '${t.date.day} ${monthShort[t.date.month - 1]}${withYear ? ' ${t.date.year}' : ''}';
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.18),
            child: Icon(_icons[t.category] ?? Icons.sell_rounded, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('$date · ${categoryLabel(t.category)}${t.oneOff ? ' · one-off' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            ]),
          ),
          const SizedBox(width: 12),
          Text(kesAmount(t.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// Add spending, or change a typed-in record ([initial]).
class _AddTxnDialog extends StatefulWidget {
  const _AddTxnDialog({this.initial});
  final Txn? initial;

  @override
  State<_AddTxnDialog> createState() => _AddTxnDialogState();
}

class _AddTxnDialogState extends State<_AddTxnDialog> {
  late final amount = TextEditingController(text: widget.initial == null ? '' : widget.initial!.amount.round().toString());
  late final note = TextEditingController(text: widget.initial?.description ?? '');
  late String category = widget.initial?.category ?? 'food_groceries';
  late DateTime date = widget.initial?.date ?? DateTime.now();
  late bool oneOff = widget.initial?.oneOff ?? false;
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
        title: Text(widget.initial == null ? 'Add spending' : 'Change this record'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [
            TextField(controller: amount, autofocus: true, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount (KES)')),
            DropdownButtonFormField<String>(
              initialValue: category,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'What was it for?'),
              items: {
                ...spendingCategories,
                // A record sorted into a category outside the list (e.g. Shopping) keeps it as a choice.
                if (!spendingCategories.containsKey(category)) category: categoryLabel(category),
              }.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
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
                  'Shown, but not counted as your usual spending. Put any loan for it under Bills, debts and goals.'),
              value: oneOff,
              onChanged: (v) => setState(() => oneOff = v),
            ),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _submit, child: Text(widget.initial == null ? 'Add' : 'Save')),
        ],
      );
}
