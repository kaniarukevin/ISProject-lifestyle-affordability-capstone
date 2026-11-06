import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/forecast_chart.dart';
import '../widgets/format.dart';
import '../widgets/panel.dart';
import 'why_score_sheet.dart';

/// Overview: lifestyle affordability and the budget forecast first (design canvas, 6 Nov).
/// Top row: the affordability score, "Can I afford it?", and what is expected to be left this month.
/// Then the budget forecast chart beside what is coming up, then anything worth knowing.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.onAddSpending, this.onOpenTab});
  final VoidCallback? onAddSpending;
  /// Switch to another tab: 1 = Can I afford it?, 2 = Forecast and budget, 3 = Plans.
  final ValueChanged<int>? onOpenTab;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Map<String, dynamic>? o;          // GET /me/overview
  Map<String, dynamic>? bf;         // GET /me/budget-forecast (null if it cannot be worked out yet)
  Map<String, dynamic>? lastCheck;  // the latest "Can I afford it?" result
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      final d = await api.overview();
      Map<String, dynamic>? f;
      Map<String, dynamic>? check;
      if (d['has_data'] == true) {
        try {
          f = await api.budgetForecast();
          if (f['has_data'] != true) f = null;
        } on ApiException {
          f = null; // for example no income yet: the rest of the overview still shows
        }
        try {
          final h = await api.scenarios();
          if (h.isNotEmpty) check = (h.first['result'] as Map).cast<String, dynamic>();
        } catch (_) {/* past checks are optional */}
      }
      if (!mounted) return;
      setState(() {
        o = d;
        bf = f;
        lastCheck = check;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e is ApiException ? e.message : 'Something went wrong loading your overview.');
    }
  }

  Future<void> _paid(int index) async {
    try {
      await context.read<AppState>().api.markPaid(index);
      await _load();
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
    if (o == null) return const Center(child: CircularProgressIndicator());
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
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          CardRow(children: [
            _ScoreCard(
              score: (d['score'] as num).round(),
              state: d['state'] as String,
              summary: d['timeline_summary'] as String?,
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
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 20),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Good to know', style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                for (final n in notes.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 7, right: 10),
                        child: CircleAvatar(radius: 3, backgroundColor: theme.colorScheme.onSurface),
                      ),
                      Expanded(child: Text(n, style: theme.textTheme.bodyMedium)),
                    ]),
                  ),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

const _onLime = Color(0xFF111111);

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.score, required this.state, this.summary});
  final int score;
  final String state;
  final String? summary;

  static const _says = {
    'Stable': 'Your income covers your usual way of life, with room to save.',
    'Strained': 'Money is tight: most of what comes in goes straight out.',
    'Critical': 'More is going out than comes in. Acting early makes it easier.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Panel(
      color: c.lime,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Affordability score', style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFF3A4214))),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text('$score',
              style: theme.textTheme.displayMedium
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1.5, height: 1, color: _onLime)),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(color: _onLime, borderRadius: BorderRadius.circular(16)),
            child: Text(state, style: theme.textTheme.labelLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 10),
        Text(_says[state] ?? '', style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFF2B3110))),
        if (summary != null) ...[
          const SizedBox(height: 4),
          Text(summary!, style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF2B3110))),
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

/// The verdict as a small coloured label: Affordable (lime), Stretch (amber), Not affordable (brown).
class VerdictChip extends StatelessWidget {
  const VerdictChip(this.verdict, {super.key, this.large = false});
  final String verdict;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (bg, fg) = switch (verdict) {
      'Affordable' => (c.lime, _onLime),
      'Stretch' => (c.warnBg, c.warn),
      _ => (const Color(0xFF7A3E00), Colors.white),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 16 : 10, vertical: large ? 6 : 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(large ? 18 : 12)),
      child: Text(verdict,
          style: TextStyle(fontFamily: 'PlusJakartaSans', color: fg, fontWeight: FontWeight.w700, fontSize: large ? 22 : 13)),
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
        Text('Can I afford it?', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('Check a purchase, a loan, a move or a new baby before you commit. Nothing is saved unless you go ahead.',
            style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: onCheck, icon: const Icon(Icons.verified_user_rounded), label: const Text('Check something')),
        if (last != null) ...[
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: 'Last check · ', style: TextStyle(color: c.muted)),
                TextSpan(text: (last['title'] ?? 'Check') as String, style: const TextStyle(fontWeight: FontWeight.w600)),
              ])),
            ),
            if (last['verdict'] is String) VerdictChip(last['verdict'] as String),
          ]),
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
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(m0 != null ? 'Expected left this month' : 'Left this month so far',
            style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
        const SizedBox(height: 4),
        Text(kesAmount(left),
            style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700, letterSpacing: -1, color: left < 0 ? c.warn : null)),
        const SizedBox(height: 4),
        Text('Before savings · $daysLeft days to go', style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
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
          child: Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 18, color: _onLime),
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
          const SizedBox(width: 6),
          Text(text, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        ]);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Budget forecast', style: theme.textTheme.titleLarge),
          key(Container(width: 16, height: 3, color: theme.colorScheme.onSurface), 'What you spent'),
          key(Container(width: 16, height: 3, color: c.muted), 'Expected'),
          key(Container(width: 14, height: 10, decoration: BoxDecoration(color: c.range, borderRadius: BorderRadius.circular(3))),
              'Likely range'),
        ]),
        const SizedBox(height: 16),
        if (f == null)
          Text('Add your income in Household and income to see the next three months.',
              style: theme.textTheme.bodyMedium?.copyWith(color: c.muted))
        else ...[
          ForecastChart(months: chartMonths(overview, f), income: ((overview['income_monthly'] ?? 0) as num).toDouble()),
          const SizedBox(height: 12),
          Text(notes.take(2).join(' '), style: theme.textTheme.bodyLarge),
          const SizedBox(height: 12),
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
        Text('Coming up', style: theme.textTheme.titleLarge),
        const SizedBox(height: 14),
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
