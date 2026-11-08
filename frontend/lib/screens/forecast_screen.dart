import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transaction.dart' show categoryLabel;
import '../services/api.dart';
import '../state/app_state.dart';
import '../state/reload_on_change.dart';
import '../theme/app_theme.dart';
import '../widgets/forecast_chart.dart';
import '../widgets/format.dart';
import '../widgets/panel.dart';
import '../widgets/busy_words.dart';
import 'budget_screen.dart';

/// Forecast and budget: the next three months at your usual pace (the plain, validated forecast), what to put
/// aside, and each budget line against what you usually spend (GET /me/budget-forecast).
class ForecastScreen extends StatefulWidget {
  const ForecastScreen({super.key});

  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> with ReloadOnChange {
  @override
  Future<void> reloadQuietly() => _load();

  Map<String, dynamic>? f;
  String? error;
  int _month = 0;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final v = p.getInt(_viewKey);
      if (v != null && mounted) setState(() => _view = v);
    });
    _showLast();
    _load();
  }

  /// The forecast from last time, at once, while the fresh one loads.
  Future<void> _showLast() async {
    final last = await context.read<AppState>().cached('forecast');
    if (last != null && mounted && f == null) setState(() => f = last);
  }

  Future<void> _load() async {
    try {
      final state = context.read<AppState>();
      final d = await state.api.budgetForecast();
      if (d['has_data'] == true) state.keep('forecast', d);
      if (!mounted) return;
      setState(() {
        f = d;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e is ApiException ? e.message : 'Something went wrong loading the forecast.');
    }
  }

  /// 0: the next three months; 1: this month's budget (both in this tab, no new page).
  int _view = 0;

  void _editBudget() => _setView(1);

  static const _viewKey = 'cache_v1_forecast_view';

  void _setView(int v) {
    setState(() => _view = v);
    SharedPreferences.getInstance().then((p) => p.setInt(_viewKey, v));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('Next 3 months'), icon: Icon(Icons.show_chart_rounded)),
              ButtonSegment(value: 1, label: Text("This month's budget"), icon: Icon(Icons.account_balance_wallet_rounded)),
            ],
            selected: {_view},
            onSelectionChanged: (v) => _setView(v.first),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(child: _view == 1 ? const BudgetView() : _forecast(context)),
      ]);

  Widget _forecast(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    if (error != null && f == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(error!, textAlign: TextAlign.center)),
          OutlinedButton(onPressed: () {
            setState(() => error = null);
            _load();
          }, child: const Text('Try again')),
        ]),
      );
    }
    if (f == null) return const BusyCenter(forecastWords);
    final d = f!;
    if (d['has_data'] != true) {
      return Center(
        child: Text('The forecast appears once there are some records.', style: theme.textTheme.bodyLarge),
      );
    }
    final months = (d['months'] as List).cast<Map<String, dynamic>>();
    final sel = months[_month.clamp(0, months.length - 1)];
    final lines = (sel['lines'] as List).cast<Map<String, dynamic>>()
      ..sort((a, b) => (b['budget'] as num).compareTo(a['budget'] as num));
    final putAside = d['put_aside'] as Map<String, dynamic>?;
    final path = (d['savings_path'] as List).cast<Map<String, dynamic>>();
    final notes = (d['notes'] as List).cast<String>();
    final planned = lines.fold<num>(0, (s, l) => s + (l['budget'] as num));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Text(d['based_on'] == 'setup'
              ? 'Based on the rough figures you gave at setup'
              : 'Based on ${d['months_used']} month(s) of your records',
              style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
          const SizedBox(height: 16),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('Spending: your months and the next three', style: theme.textTheme.titleLarge),
                _Key(mark: Container(width: 16, height: 3, color: theme.colorScheme.onSurface), text: 'What you spent'),
                _Key(mark: Container(width: 16, height: 3, color: c.muted), text: 'Expected'),
                _Key(mark: Container(width: 14, height: 10, decoration: BoxDecoration(color: c.range,
                    borderRadius: BorderRadius.circular(3))), text: 'Likely range'),
              ]),
              const SizedBox(height: 16),
              ForecastChart(
                height: 260,
                income: ((months.first['income'] ?? 0) as num).toDouble(),
                selected: ((d['history'] as List?)?.length ?? 0) + _month,
                months: [
                  for (final h in ((d['history'] as List?) ?? []).cast<Map<String, dynamic>>())
                    ChartMonth(monthShort[(h['month'] as int) - 1], (h['spent'] as num).toDouble()),
                  for (final m in months)
                    ChartMonth(monthShort[(m['month'] as int) - 1], (m['spending'] as num).toDouble(),
                        low: ((m['range'] as Map?)?['low'] as num?)?.toDouble(),
                        high: ((m['range'] as Map?)?['high'] as num?)?.toDouble(),
                        fees: ((m['school_fees'] ?? 0) as num).toDouble(), forecast: true),
                ],
              ),
              const SizedBox(height: 6),
              Text('Tap a month below to see its budget.', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            ]),
          ),
          const SizedBox(height: 20),
          CardRow(minWidth: 230, children: [
            for (var i = 0; i < months.length; i++)
              _MonthCard(month: months[i], first: i == 0, selected: i == _month, onTap: () => setState(() => _month = i)),
          ]),
          if (putAside != null) ...[
            const SizedBox(height: 20),
            Panel(
              color: c.lime,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.savings_rounded, color: Color(0xFF111111)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Put aside ${kesAmount(putAside['per_month_KES'] as num)} a month for the next '
                    '${putAside['months']} month(s), and ${monthLong[(putAside['for_month'] as int) - 1]} is covered.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFF111111), fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          CardRow(minWidth: 340, flex: const [2, 1], children: [
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    Text('${monthLong[(sel['month'] as int) - 1]} budget', style: theme.textTheme.titleLarge),
                    Text('KES ${money(planned)} for everyday spending',
                        style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                  ],
                ),
                const SizedBox(height: 16),
                for (final l in lines) _BudgetBar(line: l, max: lines.fold<num>(1, (m, x) =>
                    [m, x['budget'] as num, x['usual'] as num].reduce((a, b) => a > b ? a : b))),
                const SizedBox(height: 4),
                Wrap(spacing: 14, runSpacing: 6, children: [
                  _Key(mark: Container(width: 14, height: 8, color: theme.colorScheme.onSurface), text: 'Budget'),
                  _Key(mark: Container(width: 14, height: 8, color: c.muted), text: 'You usually spend'),
                  _Key(mark: Container(width: 14, height: 8, color: c.warn), text: 'Usually over budget'),
                ]),
                const SizedBox(height: 14),
                Text('Rent, loans and fees are taken out first; these are the everyday lines.',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(backgroundColor: c.field, foregroundColor: theme.colorScheme.onSurface),
                    onPressed: _editBudget,
                    child: const Text("See this month's budget"),
                  ),
                ),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (path.isNotEmpty)
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('Your savings', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 12),
                    _SavingsChart(now: d['savings_now'] as num, path: path),
                    const SizedBox(height: 12),
                    _SavingsLine(label: 'Now', value: d['savings_now'] as num),
                    const Divider(height: 24),
                    _SavingsLine(
                        label: 'End of ${monthLong[(path.last['month'] as int) - 1]}, at your usual pace',
                        value: path.last['usual_pace'] as num, from: d['savings_now'] as num),
                    const SizedBox(height: 12),
                    _SavingsLine(
                        label: 'End of ${monthLong[(path.last['month'] as int) - 1]}, if you keep to your budget',
                        value: path.last['on_budget'] as num, from: d['savings_now'] as num),
                    const SizedBox(height: 14),
                    Text(_savingsSentence(path, d['savings_now'] as num),
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: (path.last['usual_pace'] as num) < (d['savings_now'] as num) ? c.warn : null)),
                  ]),
                ),
              const SizedBox(height: 20),
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('What this means', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 10),
                  for (final n in notes)
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(n, style: theme.textTheme.bodyMedium)),
                ]),
              ),
            ]),
          ]),
        ],
      ),
    );
  }

  /// The savings path in one plain sentence: going down by how much a month, running out when, or growing.
  static String _savingsSentence(List<Map<String, dynamic>> path, num now) {
    final end = path.last['usual_pace'] as num;
    final perMonth = ((end - now) / path.length).abs();
    final out = path.where((p) => (p['usual_pace'] as num) < 0).firstOrNull;
    if (out != null) {
      return 'At your usual pace your savings run out in ${monthLong[(out['month'] as int) - 1]}. '
          'Keeping to your budget, or a smaller change, is needed before then.';
    }
    if (end < now) {
      return 'At your usual pace you spend more than comes in, so about KES ${money(perMonth)} a month comes out '
          'of your savings.';
    }
    return 'At your usual pace about KES ${money(perMonth)} a month is added to your savings.';
  }
}

class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.month, required this.first, required this.selected, required this.onTap});
  final Map<String, dynamic> month;
  final bool first;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final left = month['left_over'] as num;
    final short = left < 0;
    final fees = (month['school_fees'] ?? 0) as num;
    final range = month['range'] as Map?;
    final fg = short ? c.warn : null;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: short ? c.warnBg : theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: selected ? BorderSide(color: theme.colorScheme.onSurface, width: 2) : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: monthLong[(month['month'] as int) - 1],
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                if (first) TextSpan(text: ' · this month', style: TextStyle(color: c.muted)),
              ]), style: theme.textTheme.bodyLarge),
              const SizedBox(height: 12),
              Text(short ? 'Spending more than comes in' : 'Expected left',
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg ?? c.muted)),
              Text(money(left.abs()),
                  style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1, color: fg)),
              const SizedBox(height: 4),
              Text(
                '${short ? 'Taken from savings · ' : ''}Spending ${money(month['spending'] as num)}'
                '${fees > 0 ? ' · school fees ${money(fees)}' : range != null ? ' · likely ${money(range['low'] as num)} to ${money(range['high'] as num)}' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(color: fg ?? c.muted),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One savings figure, with how much it goes up or down from now (shown in words and colour, not just a minus).
class _SavingsLine extends StatelessWidget {
  const _SavingsLine({required this.label, required this.value, this.from});
  final String label;
  final num value;
  final num? from;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final change = from == null ? null : value - from!;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: c.muted))),
      const SizedBox(width: 12),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(value < 0 ? 'Short by KES ${money(-value)}' : 'KES ${money(value)}',
            style: theme.textTheme.titleMedium?.copyWith(color: value < 0 ? c.warn : null)),
        if (change != null && change.abs() >= 1)
          Text(change < 0 ? 'down ${money(-change)}' : 'up ${money(change)}',
              style: theme.textTheme.bodySmall?.copyWith(color: change < 0 ? c.warn : c.muted, fontWeight: FontWeight.w600)),
      ]),
    ]);
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.mark, required this.text});
  final Widget mark;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        mark,
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.of(context).muted)),
      ]);
}

/// One budget line: the budget (black) and what you usually spend (grey, amber when it is more than the budget).
class _BudgetBar extends StatelessWidget {
  const _BudgetBar({required this.line, required this.max});
  final Map<String, dynamic> line;
  final num max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final budget = line['budget'] as num, usual = line['usual'] as num;
    final over = (line['gap'] as num) > 0;
    Widget bar(num v, Color color) {
      final share = max <= 0 ? 0 : (v / max * 1000).round().clamp(0, 1000);
      return SizedBox(
        height: 8,
        child: Row(children: [
          if (share > 0) Expanded(flex: share.toInt(), child: Container(decoration: BoxDecoration(color: color,
              borderRadius: BorderRadius.circular(4)))),
          if (share < 1000) Spacer(flex: 1000 - share.toInt()),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Semantics(
        label: '${categoryLabel(line['category'] as String)}: budget ${money(budget)}, usually ${money(usual)}',
        child: ExcludeSemantics(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(categoryLabel(line['category'] as String),
                  style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600))),
              Text(money(budget), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text('  ·  usually ${money(usual)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: over ? c.warn : c.muted,
                      fontWeight: over ? FontWeight.w700 : null)),
            ]),
            const SizedBox(height: 6),
            bar(budget, theme.colorScheme.onSurface),
            const SizedBox(height: 4),
            bar(usual, over ? c.warn : c.muted),
          ]),
        ),
      ),
    );
  }
}

/// Savings from now to the end of the forecast: at your usual pace (dashed) and on budget (solid).
class _SavingsChart extends StatelessWidget {
  const _SavingsChart({required this.now, required this.path});
  final num now;
  final List<Map<String, dynamic>> path;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Savings now ${money(now)}; at your usual pace ${path.map((p) => money(p['usual_pace'] as num)).join(', ')}; '
            'on budget ${path.map((p) => money(p['on_budget'] as num)).join(', ')}.',
        child: ExcludeSemantics(
          child: SizedBox(
            height: 130,
            child: CustomPaint(size: Size.infinite, painter: _SavingsPainter(now, path, Theme.of(context), AppColors.of(context))),
          ),
        ),
      );
}

class _SavingsPainter extends CustomPainter {
  _SavingsPainter(this.now, this.path, this.theme, this.c);
  final num now;
  final List<Map<String, dynamic>> path;
  final ThemeData theme;
  final AppColors c;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 14.0, bottom = 22.0, side = 24.0;
    final usual = [now, for (final p in path) p['usual_pace'] as num];
    final plan = [now, for (final p in path) p['on_budget'] as num];
    final all = [...usual, ...plan, 0];
    final lo = all.reduce((a, b) => a < b ? a : b).toDouble(), hi = all.reduce((a, b) => a > b ? a : b).toDouble();
    final span = (hi - lo) == 0 ? 1.0 : hi - lo;
    double x(int i) => side + (size.width - 2 * side) * i / (usual.length - 1);
    double y(num v) => top + (size.height - top - bottom) * (1 - (v - lo) / span);
    final ink = theme.colorScheme.onSurface;
    if (lo < 0) {                                    // the zero line, when savings would go below it
      canvas.drawLine(Offset(side, y(0)), Offset(size.width - side, y(0)), Paint()..color = c.warn..strokeWidth = 1);
    }
    void line(List<num> vs, Color color, {bool dashed = false}) {
      final paint = Paint()..color = color..strokeWidth = 2.5..strokeCap = StrokeCap.round;
      for (var i = 1; i < vs.length; i++) {
        final a = Offset(x(i - 1), y(vs[i - 1])), b = Offset(x(i), y(vs[i]));
        if (!dashed) {
          canvas.drawLine(a, b, paint);
          continue;
        }
        final d = (b - a).distance, dir = (b - a) / (d == 0 ? 1 : d);
        for (var t = 0.0; t < d; t += 12) {
          canvas.drawLine(a + dir * t, a + dir * (t + 6 > d ? d : t + 6), paint);
        }
      }
      for (var i = 0; i < vs.length; i++) {
        canvas.drawCircle(Offset(x(i), y(vs[i])), 4, Paint()..color = vs[i] < 0 ? c.warn : color);
      }
    }
    line(plan, ink);
    line(usual, usual.last < now ? c.warn : c.muted, dashed: true);
    final labels = ['Now', for (final p in path) monthShort[(p['month'] as int) - 1]];
    for (var i = 0; i < labels.length; i++) {
      final tp = TextPainter(
          text: TextSpan(text: labels[i], style: TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12, color: c.muted)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(x(i) - tp.width / 2, size.height - 16));
    }
  }

  @override
  bool shouldRepaint(_SavingsPainter old) => old.now != now || old.path != path || old.theme != theme;
}

