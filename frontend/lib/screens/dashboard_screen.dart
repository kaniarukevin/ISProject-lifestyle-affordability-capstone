import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import '../state/reload_on_change.dart';
import '../theme/app_theme.dart';
import '../widgets/forecast_chart.dart';
import '../widgets/format.dart';
import '../widgets/model_note.dart';
import '../widgets/money_in.dart';
import '../widgets/note_row.dart';
import '../widgets/panel.dart';
import '../widgets/rating_row.dart';
import '../widgets/start_here.dart';
import '../widgets/state_chip.dart';
import '../widgets/state_words.dart';
import '../widgets/verdict.dart';
import 'payees_screen.dart';
import 'why_score_sheet.dart';

/// Overview: lifestyle affordability and the budget forecast first (design canvas, 6 Nov).
/// Top row: the affordability score, "Can I afford it?", and what is expected to be left this month.
/// Then the budget forecast chart beside what is coming up, then anything worth knowing.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.onAddSpending, this.onOpenTab, this.onOpenRecords});
  final VoidCallback? onAddSpending;
  /// Open Records inside this tab at a month ('YYYY-MM').
  final ValueChanged<String>? onOpenRecords;
  /// Switch to another tab: 1 = Can I afford it?, 2 = Budget and next 3 months, 3 = Bills, debts and goals.
  final ValueChanged<int>? onOpenTab;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with ReloadOnChange {
  @override
  Future<void> reloadQuietly() => _load();

  Map<String, dynamic>? o;          // GET /me/overview
  Map<String, dynamic>? bf;         // GET /me/budget-forecast (null if it cannot be worked out yet)
  Map<String, dynamic>? lastCheck;  // the latest "Can I afford it?" result
  String? error;
  bool _stale = false;              // showing the last figures while fresh ones load

  @override
  void initState() {
    super.initState();
    _showLast();
    _load();
  }

  /// The figures from last time, at once (fetching fresh ones takes a few seconds on a slow connection).
  Future<void> _showLast() async {
    final state = context.read<AppState>();
    final last = await state.cached('overview');
    if (last == null || !mounted || o != null) return;
    final f = await state.cached('forecast');
    if (!mounted || o != null) return;
    setState(() {
      o = last;
      bf = f;
      _stale = true;
    });
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      // The three requests go out together: each one waits on the database, so one after another was slow.
      final forecast = api.budgetForecast().then<Map<String, dynamic>?>((f) => f['has_data'] == true ? f : null,
          onError: (_) => null); // for example no income yet: the rest of the overview still shows
      final checks = api.scenarios().then<Map<String, dynamic>?>(
          (h) => h.isEmpty ? null : (h.first['result'] as Map).cast<String, dynamic>(),
          onError: (_) => null); // past checks are optional
      final d = await api.overview();
      final f = await forecast;
      final check = await checks;
      if (!mounted) return;
      setState(() {
        o = d;
        bf = f;
        lastCheck = check;
        error = null;
        _stale = false;
      });
      final state = context.read<AppState>();
      state.keep('overview', d);
      state.keep('forecast', f);
    } catch (e) {
      if (mounted) setState(() => error = e is ApiException ? e.message : 'Something went wrong loading your overview.');
    }
  }

  Future<void> _paid(int index) async {
    try {
      await context.read<AppState>().api.markPaid(index);   // the overview reloads by itself after a change
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (error != null && o == null) {
      return _Message(text: error!, action: 'Try again', onAction: () {
        setState(() => error = null);
        _load();
      });
    }
    if (o == null) return const _Placeholder();
    final d = o!;
    if (d['has_data'] != true) {
      return _Message(
        text: 'Your overview appears once there are some records. Upload an M-PESA statement or type in your spending.',
        action: 'Add records',
        onAction: widget.onAddSpending,
      );
    }
    final notes = ((d['notes'] as List?) ?? []).cast<String>();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (_stale)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('Showing your last figures, updating…', style: theme.textTheme.bodySmall),
              ]),
            ),
          StartHere(
            hasStatement: d['estimated'] != true,
            sorted: d['estimated'] != true && ((d['unsorted_share'] ?? 0) as num) <= 0.10,
            checked: lastCheck != null,
            onAddStatement: () => widget.onAddSpending?.call(),
            onSort: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PayeesScreen())),
            onBudget: () => widget.onOpenTab?.call(2),
            onCheck: () => widget.onOpenTab?.call(1),
          ),
          if (d['savings_check'] != null) ...[
            _SavingsCheckCard(check: (d['savings_check'] as Map).cast<String, dynamic>()),
            const SizedBox(height: 20),
          ],
          if (d['income_gap'] != null) ...[
            _IncomeGapCard(gap: (d['income_gap'] as Map).cast<String, dynamic>()),
            const SizedBox(height: 20),
          ],
          CardRow(children: [
            _ScoreCard(
              score: (d['score'] as num).round(),
              state: d['state'] as String,
              nextMonth: d['next_month'] as String?,
              facts: _scoreFacts(d),
              estimated: d['estimated'] == true,
            ),
            _AffordCard(lastCheck: lastCheck, onCheck: () => widget.onOpenTab?.call(1)),
            _LeftCard(overview: d, forecast: bf),
          ]),
          const SizedBox(height: 20),
          CardRow(minWidth: 340, flex: const [2, 1], children: [
            _ForecastCard(overview: d, forecast: bf, onMore: () => widget.onOpenTab?.call(2)),
            _ComingUpCard(
              bills: ((d['bills_due'] as List?) ?? []).cast<Map<String, dynamic>>(),
              goals: ((d['goals_at_risk'] as List?) ?? []).cast<Map<String, dynamic>>(),
              onPaid: _paid,
              onAll: () => widget.onOpenTab?.call(3),
            ),
          ]),
          if (((d['timeline'] as List?) ?? []).isNotEmpty) ...[
            const SizedBox(height: 20),
            _YearCard(
              months: (d['timeline'] as List).cast<Map<String, dynamic>>(),
              onOpen: (key) => widget.onOpenRecords?.call(key),
            ),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 20),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const PanelTitle('Good to know', icon: Icons.auto_awesome_rounded),
                const SizedBox(height: 16),
                for (final n in notes.take(5)) NoteRow(n),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          const RatingCard(where: 'overview', question: 'Does this overview match your real finances?'),
          const ModelNote(),
        ],
      ),
    );
  }
}

/// The figures behind the word, so anyone can check it against their own M-PESA (11 Nov: testers who never think
/// of their money as a "state" had no way to tell whether the word was right).
String? _scoreFacts(Map<String, dynamic> d) {
  // The LAST COMPLETE month, never the one in progress (11 Nov: a half-finished November read as "KES 1,363 went
  // out", which made the card look broken).
  final months = ((d['timeline'] as List?) ?? []).cast<Map<String, dynamic>>();
  if (months.isEmpty) return null;
  final m = months.last;
  final spent = (m['spent'] as num?)?.round() ?? 0;
  final income = (m['income'] as num?)?.round() ?? 0;
  if (income <= 0) return null;
  final line = 'In ${_monthShort[(m['month'] as int) - 1]} about KES ${money(spent)} went out and about '
      'KES ${money(income)} came in.';
  final rec = (d['track_record'] as Map?)?.cast<String, dynamic>();
  final over = (rec?['overspent_months'] as num?)?.toInt() ?? 0;
  final of = (rec?['months'] as num?)?.toInt() ?? 0;
  if (of >= 3 && over > 0) return '$line In $over of your last $of months you spent more than came in.';
  if (of >= 3) return '$line Your last $of months all stayed inside what came in.';
  return line;
}

const _monthShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const _onLime = Color(0xFF111111);

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.score, required this.state, this.nextMonth, this.facts, this.estimated = false});
  final int score;
  final String state;
  final String? nextMonth;   // what next month looks like: the score is a fair one-month warning (10 Nov)
  final String? facts;       // the figures behind the word, so anyone can check it
  final bool estimated;      // still the setup figures, not a real statement

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Panel(
      color: c.lime,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: const Icon(Icons.speed_rounded, size: 17, color: _onLime),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Your money score', style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFF3A4214))),
          ),
          if (estimated)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: _onLime, borderRadius: BorderRadius.circular(12)),
              child: const Text('A guess for now',
                  style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text('$score',
              style: theme.textTheme.displayMedium
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1.5, height: 1, color: _onLime)),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 14),
            child: Text('/ 100', style: theme.textTheme.titleMedium?.copyWith(color: const Color(0xFF3A4214))),
          ),
          const SizedBox(width: 12),
          StateChip(state: state, background: Colors.white, ink: _onLime),
        ]),
        const SizedBox(height: 10),
        Text(stateMeaning(state), style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFF2B3110))),
        if (facts != null) ...[
          const SizedBox(height: 6),
          Text(facts!, style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF2B3110))),
        ],
        if (estimated) ...[
          const SizedBox(height: 6),
          Text('Add your M-PESA statement and this becomes your real score.',
              style: theme.textTheme.bodyMedium?.copyWith(color: _onLime, fontWeight: FontWeight.w600)),
        ],
        if (nextMonth != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0x14000000), borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.east_rounded, size: 18, color: _onLime),
              const SizedBox(width: 8),
              Expanded(
                child: Text(nextMonth!,
                    style: theme.textTheme.bodyMedium?.copyWith(color: _onLime, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _onLime, foregroundColor: Colors.white),
          onPressed: () => showWhyScore(context),
          child: const Text('Why this score?'),
        ),
      ]),
    );
  }
}

class _AffordCard extends StatelessWidget {
  const _AffordCard({required this.lastCheck, required this.onCheck});
  final Map<String, dynamic>? lastCheck;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final last = lastCheck;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PanelTitle('Can I afford it?', icon: Icons.price_check_rounded),
        const SizedBox(height: 12),
        Text('Check a purchase, a loan, a move or a new baby before you commit. Nothing is saved unless you go ahead.',
            style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onCheck,
            icon: const Icon(Icons.verified_user_rounded),
            label: const Text('Check something'),
          ),
        ),
        if (last != null) ...[
          const SizedBox(height: 18),
          // The verdict above the thing it is about: side by side they fought for the same line and the chip
          // was squeezed to nothing (11 Nov).
          Material(
            color: c.field,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              onTap: onCheck,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('YOUR LAST CHECK',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: c.muted, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
                  const SizedBox(height: 8),
                  if (last['verdict'] is String) ...[
                    VerdictChip(last['verdict'] as String),
                    const SizedBox(height: 8),
                  ],
                  Text((last['title'] ?? 'Check') as String,
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

class _LeftCard extends StatelessWidget {
  const _LeftCard({required this.overview, required this.forecast});
  final Map<String, dynamic> overview;
  final Map<String, dynamic>? forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final now = DateTime.now();
    final daysLeft = DateUtils.getDaysInMonth(now.year, now.month) - now.day + 1;
    final months = ((forecast?['months'] as List?) ?? []).cast<Map<String, dynamic>>();
    final latest = (overview['latest'] as Map).cast<String, dynamic>();
    final m0 = months.isNotEmpty ? months.first : null;
    final left = (m0?['left_over'] ?? latest['left_over']) as num;
    final income = (m0?['income'] ?? overview['income_monthly']) as num;
    final spending = (m0?['spending'] ?? latest['spent']) as num;
    final savings = ((overview['savings_balance'] ?? 0) as num);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Short: say it in words and show the amount without a minus sign (a "-KES 4,261" read as a typo).
        Text(left < 0
                ? 'Expected to spend more than comes in'
                : m0 != null ? 'Expected left this month' : 'Left this month so far',
            style: theme.textTheme.bodyLarge?.copyWith(color: left < 0 ? c.warn : c.muted)),
        const SizedBox(height: 4),
        Text(kesAmount(left.abs()),
            style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700, letterSpacing: -1, color: left < 0 ? c.warn : null)),
        const SizedBox(height: 4),
        Text(
          left >= 0
              ? 'Before savings · $daysLeft days to go'
              : savings >= -left
                  ? 'This comes out of your savings, which go down to ${kesAmount(savings + left)} · $daysLeft days to go'
                  : 'More than your savings (${kesAmount(savings)}) can cover · $daysLeft days to go',
          style: theme.textTheme.bodyMedium?.copyWith(color: left < 0 ? c.warn : c.muted),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(22)),
          child: Row(children: [
            Expanded(child: _InOut(up: true, label: 'Money in', value: income)),
            Expanded(child: _InOut(up: false, label: m0 != null ? 'Expected spending' : 'Spent', value: spending)),
          ]),
        ),
      ]),
    );
  }
}

class _InOut extends StatelessWidget {
  const _InOut({required this.up, required this.label, required this.value});
  final bool up;
  final String label;
  final num value;

  @override
  Widget build(BuildContext context) => Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: Colors.white,
          // Into your wallet points in, out of it points away (10 Nov: testers read the up/down arrows the other way).
          child: Icon(up ? Icons.south_west_rounded : Icons.north_east_rounded, size: 18, color: _onLime),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFFBDBDB6))),
            Text(money(value), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
          ]),
        ),
      ]);
}

/// The chart months: up to five recorded months, then the forecast's three.
List<ChartMonth> chartMonths(Map<String, dynamic> overview, Map<String, dynamic>? forecast) {
  final next = ((forecast?['months'] as List?) ?? []).cast<Map<String, dynamic>>();
  final firstNext = next.isEmpty ? 1 << 30 : (next.first['year'] as int) * 12 + (next.first['month'] as int);
  final past = ((overview['history'] as List?) ?? [])
      .cast<Map<String, dynamic>>()
      .where((h) => (h['year'] as int) * 12 + (h['month'] as int) < firstNext)
      .toList();
  final shown = past.length > 5 ? past.sublist(past.length - 5) : past;
  return [
    for (final h in shown) ChartMonth(monthShort[(h['month'] as int) - 1], (h['spent'] as num).toDouble()),
    for (final m in next)
      ChartMonth(
        monthShort[(m['month'] as int) - 1],
        (m['spending'] as num).toDouble(),
        low: ((m['range'] as Map?)?['low'] as num?)?.toDouble(),
        high: ((m['range'] as Map?)?['high'] as num?)?.toDouble(),
        fees: ((m['school_fees'] ?? 0) as num).toDouble(),
        forecast: true,
      ),
  ];
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({required this.overview, required this.forecast, required this.onMore});
  final Map<String, dynamic> overview;
  final Map<String, dynamic>? forecast;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final f = forecast;
    final notes = ((f?['notes'] as List?) ?? []).cast<String>();
    Widget key(Widget mark, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          mark,
          const SizedBox(width: 7),
          Text(text, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        ]);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PanelTitle('The next 3 months', icon: Icons.show_chart_rounded),
        const SizedBox(height: 12),
        if (f == null)
          Text('Add your income in Household and income to see the next three months.',
              style: theme.textTheme.bodyMedium?.copyWith(color: c.muted))
        else ...[
          // One line of plain English before the chart: testers could not work out which line was which, or
          // which months had already happened (11 Nov).
          Text('Left of the dotted line is what you really spent. Right of it is what the app expects.',
              style: theme.textTheme.bodyMedium?.copyWith(color: c.muted, height: 1.35)),
          const SizedBox(height: 14),
          ForecastChart(months: chartMonths(overview, f), income: ((overview['income_monthly'] ?? 0) as num).toDouble()),
          const SizedBox(height: 10),
          Wrap(spacing: 16, runSpacing: 8, children: [
            key(Container(width: 18, height: 3, color: theme.colorScheme.onSurface), 'What you spent'),
            key(_DottedKey(color: c.muted), 'What the app expects'),
            key(
                Container(
                    width: 16,
                    height: 11,
                    decoration: BoxDecoration(color: c.range, borderRadius: BorderRadius.circular(3))),
                'Could land anywhere in here'),
            key(_DottedKey(color: c.warn), 'Your income'),
          ]),
          const SizedBox(height: 16),
          // Each note on its own line: run together in one paragraph they read as a broken sentence (11 Nov).
          for (final n in notes.take(2))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 10),
                  child: CircleAvatar(radius: 3, backgroundColor: c.muted),
                ),
                Expanded(child: Text(n, style: theme.textTheme.bodyLarge?.copyWith(height: 1.35))),
              ]),
            ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            style: FilledButton.styleFrom(backgroundColor: c.field, foregroundColor: theme.colorScheme.onSurface),
            onPressed: onMore,
            child: const Text('See the full forecast'),
          ),
        ],
      ]),
    );
  }
}

/// A short dotted dash for the chart key, so a dotted line in the key looks like the dotted line on the chart.
class _DottedKey extends StatelessWidget {
  const _DottedKey({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Container(width: 4, height: 3, color: color),
        ],
      ]);
}

class _ComingUpCard extends StatelessWidget {
  const _ComingUpCard({required this.bills, required this.goals, required this.onPaid, required this.onAll});
  final List<Map<String, dynamic>> bills;
  final List<Map<String, dynamic>> goals;
  final ValueChanged<int> onPaid;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PanelTitle('Coming up', icon: Icons.event_outlined),
        const SizedBox(height: 16),
        if (bills.isEmpty && goals.isEmpty)
          Text('Nothing due in the next week.', style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        for (final b in bills) ...[
          Builder(builder: (context) {
            final days = (b['due_in_days'] as num).toInt();
            final due = today.add(Duration(days: days));
            return Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: c.field, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(monthShort[due.month - 1].toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(color: c.muted, fontWeight: FontWeight.w700, height: 1)),
                  Text('${due.day}', style: theme.textTheme.titleMedium?.copyWith(height: 1.1)),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b['name'] as String, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    days < 0 ? '${-days} days late' : days == 0 ? 'Due today' : 'in $days days',
                    style: theme.textTheme.bodySmall?.copyWith(color: days < 0 ? c.warn : c.muted),
                  ),
                ]),
              ),
              Text(money(b['amount_KES'] as num), style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              TextButton(onPressed: () => onPaid((b['index'] as num).toInt()), child: const Text('Paid')),
            ]);
          }),
          const SizedBox(height: 12),
        ],
        for (final g in goals) ...[
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: c.warnBg, shape: BoxShape.circle),
              child: Icon(Icons.flag_rounded, color: c.warn, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(g['name'] as String, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                Text('At risk: needs ${kesAmount(g['monthly_needed_KES'] as num)} a month',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.warn)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 4),
        TextButton(onPressed: onAll, child: const Text('All bills, debts and goals')),
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, this.onAction});
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Panel(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
              if (action != null && onAction != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onAction, child: Text(action!)),
              ],
            ]),
          ),
        ),
      );
}

/// Grey cards in the shape of the real ones, while the first figures load (instead of a bare spinner).
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(color: c.range, borderRadius: BorderRadius.circular(8)),
        );
    Widget card(double h) => Panel(
          child: SizedBox(
            height: h,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(120, 14), bar(180, 40), bar(220, 12)]),
          ),
        );
    return Semantics(
      label: 'Loading your overview',
      child: ListView(physics: const NeverScrollableScrollPhysics(), children: [
        CardRow(children: [card(170), card(170), card(170)]),
        const SizedBox(height: 20),
        CardRow(minWidth: 340, flex: const [2, 1], children: [card(260), card(260)]),
      ]),
    );
  }
}



/// "Your year": every scored month as a tile with its state and score, newest on the right. Tap one for that
/// month's figures and a way into its records (lifestyle tracking over time, proposal R22).
class _YearCard extends StatelessWidget {
  const _YearCard({required this.months, required this.onOpen});
  final List<Map<String, dynamic>> months;
  final ValueChanged<String> onOpen;

  static const _short = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static const _long = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
    'October', 'November', 'December'];

  String _kes(num v) => 'KES ${v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')}';

  void _show(BuildContext context, Map<String, dynamic> m) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final key = '${m['year']}-${(m['month'] as int).toString().padLeft(2, '0')}';
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${_long[(m['month'] as int) - 1]} ${m['year']}', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: StateChip(state: m['state'] as String, score: m['score'] as int)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: Text('Money in', style: TextStyle(color: c.muted))),
              Text(_kes(m['income'] as num), style: const TextStyle(fontWeight: FontWeight.w600)),
              if (m['income_from'] == 'you')
                Padding(padding: const EdgeInsets.only(left: 6), child: Text('· set by you', style: TextStyle(color: c.muted))),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  editMonthIncome(context, m['year'] as int, m['month'] as int, m['income'] as num,
                      setByYou: m['income_from'] == 'you');
                },
                child: const Text('Change'),
              ),
            ]),
            for (final (label, value) in [
              ('Spent', m['spent'] as num),
              ('Saved', m['saved'] as num),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Expanded(child: Text(label, style: TextStyle(color: c.muted))),
                  Text(_kes(value), style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
            if (m['estimated'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Partly from the rough figures you gave at setup.',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                onOpen(key);
              },
              child: const Text("See this month's records"),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final shown = months.length > 12 ? months.sublist(months.length - 12) : months;
    final counts = {for (final s in ['Stable', 'Strained', 'Critical']) s: shown.where((m) => m['state'] == s).length};
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PanelTitle('Your year', icon: Icons.grid_view_rounded),
        const SizedBox(height: 10),
        Text(
            'Each square is a month: ${counts['Stable']} doing fine, ${counts['Strained']} stretched and '
            '${counts['Critical']} struggling. Tap a month to see it.',
            style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, box) {
          const gap = 8.0;
          final per = box.maxWidth >= 720 ? 12 : 6;
          final w = (box.maxWidth - gap * (per - 1)) / per;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (final m in shown)
              SizedBox(width: w, child: _MonthTile(m: m, label: _short[(m['month'] as int) - 1], onTap: () => _show(context, m))),
          ]);
        }),
        const SizedBox(height: 12),
        Wrap(spacing: 16, runSpacing: 6, children: [
          for (final s in ['Stable', 'Strained', 'Critical'])
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                      color: stateColor(c, s), shape: BoxShape.circle, border: Border.all(color: const Color(0x22000000)))),
              const SizedBox(width: 6),
              Text(stateLabel(s), style: theme.textTheme.bodySmall),
            ]),
        ]),
      ]),
    );
  }
}

class _MonthTile extends StatelessWidget {
  const _MonthTile({required this.m, required this.label, required this.onTap});
  final Map<String, dynamic> m;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final state = m['state'] as String;
    final fg = stateInk(context, state);
    return Tooltip(
      message: '$label: ${stateLabel(state)}, ${scoreOutOf(m['score'] as num)}',
      child: Material(
        color: stateColor(c, state),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(children: [
              Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 12)),
              // The score, not a letter: Stable and Strained both start with S.
              Text('${m['score']}', style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 18)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "Is your savings balance still KES X?" (10 Nov). The balance is a snapshot from the day it was typed, so past
/// records are never added to it; once it is a month old Tosha asks, since checks look ahead using it.
class _SavingsCheckCard extends StatefulWidget {
  const _SavingsCheckCard({required this.check});
  final Map<String, dynamic> check;

  @override
  State<_SavingsCheckCard> createState() => _SavingsCheckCardState();
}

class _SavingsCheckCardState extends State<_SavingsCheckCard> {
  bool busy = false;
  static const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  Future<void> _save([double? balance]) async {
    setState(() => busy = true);
    try {
      await context.read<AppState>().api.confirmSavings(balance);   // the overview reloads by itself
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _update() async {
    final ctl = TextEditingController();
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your savings today'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(prefixText: 'KES ', helperText: 'All of it together: M-Shwari, SACCO, bank, cash'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final x = double.tryParse(ctl.text.replaceAll(',', '').trim());
              if (x != null && x.isFinite && x >= 0 && x < 100000000) Navigator.pop(ctx, x);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (v != null) await _save(v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final k = widget.check;
    final since = k['set_on'] as String?;
    final saved = (k['saved_since_KES'] as num?) ?? 0;
    final when = since == null ? null : DateTime.tryParse(since);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Is your savings still KES ${money(k['balance_KES'] as num)}?', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
            '${when == null ? 'We are not sure when you told us.' : 'You told us on ${when.day} ${_monthNames[when.month - 1]}.'}'
            '${saved > 0 ? ' Since then about KES ${money(saved)} went into savings.' : ''}'
            ' Tosha uses it to say how long your savings could cover a gap.',
            style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 8, children: [
          FilledButton(onPressed: busy ? null : _update, child: const Text('Update it')),
          OutlinedButton(onPressed: busy ? null : () => _save(), child: const Text('Yes, still right')),
        ]),
      ]),
    );
  }
}

/// The statement shows clearly less money coming in than the user said (8 Nov: a 16,000 salary on M-PESA, the
/// rest of a 30,000 income paid to a bank). Tosha asks once instead of scoring the months as poorer.
class _IncomeGapCard extends StatelessWidget {
  const _IncomeGapCard({required this.gap});
  final Map<String, dynamic> gap;

  String _kes(num v) => 'KES ${v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.help_rounded, color: theme.colorScheme.onSurface),
          const SizedBox(width: 10),
          Expanded(child: Text('Does some of your money come outside M-PESA?', style: theme.textTheme.titleLarge)),
        ]),
        const SizedBox(height: 8),
        Text('Your statement shows about ${_kes(gap['statement_KES'] as num)} coming in each month, but you told us '
            'you have about ${_kes(gap['profile_KES'] as num)}. Tosha only sees M-PESA, so money paid to a bank or '
            'in cash is missing, and your months look tighter than they were.',
            style: TextStyle(color: c.muted)),
        const SizedBox(height: 14),
        Wrap(spacing: 10, runSpacing: 8, children: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.lime, foregroundColor: c.onLime),
            onPressed: () => editOutsideMoney(context, income: gap['gap_KES'] as num),
            child: const Text('Yes, set it up'),
          ),
          FilledButton.tonal(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await context.read<AppState>().api.dismissIncomeGap();
              messenger.showSnackBar(const SnackBar(
                  content: Text('Understood. If your income changed, update it under You, Household and income.')));
            },
            child: Text('No, ${_kes(gap['statement_KES'] as num)} is right'),
          ),
        ]),
      ]),
    );
  }
}
