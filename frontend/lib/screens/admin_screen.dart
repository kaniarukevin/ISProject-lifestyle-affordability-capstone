import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/format.dart';
import '../widgets/panel.dart';
import '../widgets/busy_words.dart';
import 'home_screen.dart';
import 'privacy_screen.dart';

const _dests = [
  NavDest('Overview', 'Overview', Icons.home_rounded),
  NavDest('Models', 'Models', Icons.insights_rounded),
  NavDest('Real use: ratings, sorting, usage', 'Real use', Icons.fact_check_rounded),
  NavDest('Performance and logs', 'Performance and logs', Icons.speed_rounded),
  NavDest('Datasets', 'Datasets', Icons.dataset_rounded),
  NavDest('Users', 'Users', Icons.group_rounded),
  NavDest('Settings', 'Settings', Icons.settings_rounded),
];

/// The admin console (proposal 3.4.1, the System Administrator): its own frame with the same rail and pill bar
/// as the household app. Overview (is it working, how many people use it), Models (each model against its
/// baseline on held-out data), Real use (ratings, sorting kept or corrected, the forecast on real months, feature
/// use), Performance and logs, Datasets, Users (masked; pause or delete, with a permanent record of admin
/// actions) and Settings. Figures come from the /admin endpoints; nothing is typed into the app.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  int _tab = 0;
  Map<String, dynamic>? overview;
  Map<String, dynamic>? reports;
  Map<String, dynamic>? perf;
  Map<String, dynamic>? valid;
  String? error;
  int _busy = 0;               // requests in flight; the page stays on screen with a thin bar while > 0
  DateTime? _updated;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refreshAll();
    // Live figures (health, users, performance) refresh by themselves every 30 s while the console is open,
    // quietly and only the part that changes. Model results and datasets do not change while running.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_tab == 0 || _tab == 5) _fetch('overview', quiet: true);
      if (_tab == 0 || _tab == 3) _fetch('perf', quiet: true);
      if (_tab == 2 || _tab == 5) _fetch('valid', quiet: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// What each page needs: only that is fetched when it is refreshed.
  static const _needs = {
    0: ['overview', 'perf'],
    1: ['reports'],
    2: ['valid', 'overview'],
    3: ['perf'],
    4: ['reports'],
    5: ['overview', 'valid'],
    6: <String>[],
  };

  Future<void> _refreshAll() =>
      Future.wait([_fetch('overview'), _fetch('reports'), _fetch('perf'), _fetch('valid')]);

  Future<void> _refreshPage() => Future.wait([for (final k in _needs[_tab]!) _fetch(k)]);

  Future<void> _fetch(String what, {bool quiet = false}) async {
    final api = context.read<AppState>().api;
    if (!quiet) setState(() => _busy++);
    try {
      final d = await switch (what) {
        'overview' => api.adminOverview(),
        'reports' => api.adminReports(),
        'valid' => api.adminValidation(),
        _ => api.adminPerformance(),
      };
      if (!mounted) return;
      setState(() {
        switch (what) {
          case 'overview':
            overview = d;
          case 'reports':
            reports = d;
          case 'valid':
            valid = d;
          default:
            perf = d;
        }
        error = null;
        _updated = DateTime.now();
      });
    } on ApiException catch (e) {
      if (mounted && !quiet) setState(() => error = e.message);
    } finally {
      if (mounted && !quiet) setState(() => _busy--);
    }
  }

  void _go(int i) {
    setState(() => _tab = i);
    if (i == 3) _fetch('perf', quiet: true);       // the newest timings whenever the page is opened
    if (i == 2) _fetch('valid', quiet: true);
  }

  Widget _body() {
    if (overview == null || reports == null || perf == null) {
      return Center(
        child: error != null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                Text(error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(onPressed: _refreshAll, child: const Text('Try again')),
              ])
            : const BusyCenter(adminWords),
      );
    }
    final page = switch (_tab) {
      0 => _OverviewPage(d: overview!, perf: perf!, onOpen: _go),
      1 => _ModelsPage(models: _list(reports!['models'])),
      // Real use loads on its own: if it fails, only this page says so, and the rest of the console still works.
      2 => valid == null
          ? Center(child: Text(error ?? 'Loading…', textAlign: TextAlign.center))
          : _RealUsePage(v: valid!, real: overview!['forecast_on_real_months'] as Map<String, dynamic>?),
      3 => _PerformancePage(p: perf!),
      4 => _DatasetsPage(sets: _list(reports!['datasets'])),
      5 => _UsersPage(
          users: _list(overview!['recent_users']),
          total: (overview!['users'] as Map)['total'] as int,
          actions: _list(valid?['admin_actions']),
          onChanged: () => Future.wait([_fetch('overview'), _fetch('valid')])),
      _ => const _SettingsPage(),
    };
    return RefreshIndicator(onRefresh: _refreshPage, child: page);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= HomeScreen.wideFrom;
        final theme = Theme.of(context);
        final c = AppColors.of(context);
        final page = Padding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 16 : 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.only(top: wide ? 18 : 16, bottom: 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        _updated == null
                            ? 'Tosha admin'
                            : 'Tosha admin · updated ${_updated!.hour.toString().padLeft(2, '0')}:'
                                '${_updated!.minute.toString().padLeft(2, '0')}:${_updated!.second.toString().padLeft(2, '0')}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
                    Text(_dests[_tab].title, style: wide ? theme.textTheme.headlineMedium : theme.textTheme.headlineSmall),
                  ]),
                ),
                if (!wide) ...[
                  IconButton.filledTonal(
                      tooltip: 'Settings', onPressed: () => _go(6), icon: const Icon(Icons.settings_rounded)),
                  const SizedBox(width: 8),
                ],
                IconButton.filledTonal(
                    tooltip: 'Refresh this page', onPressed: _busy > 0 ? null : _refreshPage,
                    icon: const Icon(Icons.refresh_rounded)),
              ]),
            ),
            SizedBox(height: 3, child: _busy > 0 && overview != null ? const LinearProgressIndicator() : null),
            const SizedBox(height: 6),
            Expanded(child: _body()),
          ]),
        );
        if (wide) {
          return Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  NavRail(dests: _dests, selected: _tab, onSelect: _go),
                  const SizedBox(width: 16),
                  Expanded(child: page),
                ]),
              ),
            ),
          );
        }
        return Scaffold(
          body: Stack(children: [
            SafeArea(bottom: false, child: Padding(padding: const EdgeInsets.only(bottom: 92), child: page)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 22 + MediaQuery.paddingOf(context).bottom,
              child: Center(
                  child: PillNav(dests: _dests.sublist(0, 6), selected: _tab < 6 ? _tab : -1, onSelect: _go)),
            ),
          ]),
        );
      });
}

List<Map<String, dynamic>> _list(Object? v) => (v as List? ?? const []).cast<Map<String, dynamic>>();

/// A scrolling page of cards with the same gaps everywhere.
class _Scroll extends StatelessWidget {
  const _Scroll({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 20), children[i]],
        ],
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.sub});
  final String text;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(text, style: theme.textTheme.titleLarge),
      if (sub != null) ...[
        const SizedBox(height: 4),
        Text(sub!, style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.of(context).muted)),
      ],
    ]);
  }
}

/// A big number with a label under it.
class _Tile extends StatelessWidget {
  const _Tile(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.of(context).muted)),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.ok});
  final String label;
  final String value;
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final icon = ok == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Icon(ok! ? Icons.check_circle_rounded : Icons.error_rounded, size: 20, color: ok! ? null : c.warn),
          );
    const strong = TextStyle(fontWeight: FontWeight.w600);
    // A short value sits on the right of its label; a long one goes underneath, so nothing is ever squeezed.
    if (value.length > 34) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: c.muted)),
          const SizedBox(height: 2),
          Text(value, style: strong),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ?icon,
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.right, style: strong)),
      ]),
    );
  }
}

// ---------------- Overview ----------------

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({required this.d, required this.perf, required this.onOpen});
  final Map<String, dynamic> d;
  final Map<String, dynamic> perf;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final s = (d['service'] as Map).cast<String, dynamic>();
    final u = (d['users'] as Map).cast<String, dynamic>();
    final models = _list(d['models']);
    final present = models.where((m) => m['present'] == true).length;
    final dataOk = s['forecast_data_loaded'] != false;
    final healthy = s['status'] == 'ok' && dataOk && present == models.length;
    return _Scroll(children: [
      Panel(
        color: healthy ? c.lime : c.warnBg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(healthy ? 'Everything is working' : 'Something needs attention',
              style: theme.textTheme.headlineSmall?.copyWith(color: healthy ? c.onLime : c.warn)),
          const SizedBox(height: 4),
          Text('API, database, models and the Web Masters forecast data, checked just now.',
              style: theme.textTheme.bodyMedium?.copyWith(color: healthy ? c.onLime : c.warn)),
        ]),
      ),
      CardRow(children: [
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const _Heading('Service'),
            const SizedBox(height: 8),
            _Line('API', '${s['status']}', ok: s['status'] == 'ok'),
            _Line('Database', '${s['database']}', ok: true),
            _Line('Models present', '$present of ${models.length}', ok: present == models.length),
            _Line('Web Masters data', dataOk ? 'loaded' : 'not loaded', ok: dataOk),
            _Line('Email (password resets)', s['email'] == true ? 'set up' : 'not set up', ok: s['email'] == true),
            _Line('Database round trip', '${perf['db_round_trip_ms']} ms',
                ok: (perf['db_round_trip_ms'] as num) < 20),
            if (perf['median_ms'] != null) _Line('Typical response', '${perf['median_ms']} ms'),
            if (s['forecast_error'] != null)
              Text('${s['forecast_error']}', style: theme.textTheme.bodySmall?.copyWith(color: c.warn)),
          ]),
        ),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const _Heading('Privacy'),
            const SizedBox(height: 8),
            _Line('Agreed to the privacy notice', '${u['agreed_privacy'] ?? '-'} of ${u['total']}'),
            const _Line('Statement files kept', 'none'),
            const _Line('Emails shown here', 'masked'),
            _Line('Rate limits read the address from', '${d['client_ip_source'] ?? '-'}'),
          ]),
        ),
      ]),
      const _Heading('People using Tosha'),
      CardRow(minWidth: 180, children: [
        _Tile('${u['total']}', 'Accounts'),
        _Tile('${u['with_household']}', 'Set up a household'),
        _Tile('${u['with_statement']}', 'Uploaded a statement'),
      ]),
      CardRow(minWidth: 180, children: [
        _Tile('${u['joined_7_days']}', 'Joined in the last 7 days'),
        _Tile(money(u['records'] as num), 'Spending records'),
        _Tile('${u['affordability_checks']}', 'Affordability checks'),
      ]),
      Wrap(spacing: 10, runSpacing: 10, children: [
        FilledButton.icon(onPressed: () => onOpen(1), icon: const Icon(Icons.insights_rounded), label: const Text('See the models')),
        FilledButton.tonal(onPressed: () => onOpen(2), child: const Text('Real use')),
        FilledButton.tonal(onPressed: () => onOpen(3), child: const Text('Performance and logs')),
        FilledButton.tonal(onPressed: () => onOpen(4), child: const Text('See the datasets')),
      ]),
    ]);
  }
}

// ---------------- Models ----------------

class _ModelsPage extends StatelessWidget {
  const _ModelsPage({required this.models});
  final List<Map<String, dynamic>> models;

  @override
  Widget build(BuildContext context) => _Scroll(children: [
        const _Heading('Each model against what it replaced',
            sub: 'Every method was compared with a baseline on held-out data before it was kept. '
                'Figures from docs/experiments.md.'),
        _Scorecard(models: models),
        for (final m in models) _ModelCard(m: m),
      ]);
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.m});
  final Map<String, dynamic> m;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final present = m['present'] == true;
    final charts = _list(m['charts']);
    final table = m['table'] as Map<String, dynamic>?;
    final facts = (m['facts'] as List? ?? const []).cast<String>();
    final dev = '${m['deviation'] ?? ''}';
    final about = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('${m['name']}', style: theme.textTheme.titleLarge)),
        _Chip(present ? 'Deployed' : 'File missing', strong: present),
      ]),
      const SizedBox(height: 6),
      Text('${m['does']}', style: theme.textTheme.bodyLarge),
      const SizedBox(height: 14),
      _Line('Proposal', '${m['proposal']}'),
      _Line('Built', '${m['built']}'),
      if (dev.isNotEmpty) _Line('Deviation', dev),
      _Line('Trained on', '${m['data']}'),
      _Line('File', present ? '${m['file']} · ${m['size_mb']} MB · ${m['updated']}' : '${m['file']}'),
      if (facts.isNotEmpty) ...[
        const SizedBox(height: 10),
        for (final f in facts)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('• $f', style: theme.textTheme.bodyMedium),
          ),
      ],
      if (m['limit'] != null) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(16)),
          child: Text('Limit: ${m['limit']}', style: theme.textTheme.bodyMedium?.copyWith(color: c.warn)),
        ),
      ],
      const SizedBox(height: 8),
      Text('Source: ${m['source']}', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
    ]);
    final results = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < charts.length; i++) ...[if (i > 0) const SizedBox(height: 22), BarChartCard(chart: charts[i])],
      if (table != null) ...[const SizedBox(height: 22), _Table(t: table)],
    ]);
    return Panel(
      child: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth < 760) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [about, const SizedBox(height: 22), results]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: about),
          const SizedBox(width: 32),
          Expanded(child: results),
        ]);
      }),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {this.strong = false});
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: strong ? c.lime : c.warnBg, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(fontWeight: FontWeight.w600, color: strong ? c.onLime : c.warn)),
    );
  }
}

/// Horizontal bars from the model register: ours in lime, the comparisons in grey. With "series", each group
/// (for example "1 month") gets one bar per series and the last series is ours.
class BarChartCard extends StatelessWidget {
  const BarChartCard({super.key, required this.chart});
  final Map<String, dynamic> chart;

  static String fmt(num v, String unit) => switch (unit) {
        'KES' => 'KES ${money(v)}',
        '%' => '${v.round()}%',
        'pts' => v.toStringAsFixed(1),
        'ms' => '${v.round()} ms',
        _ => v is int || v == v.roundToDouble() && v.abs() >= 1 ? '${v.round()}' : v.toStringAsFixed(3),
      };

  @override
  Widget build(BuildContext context) {
    if (chart['type'] == 'matrix') return _Matrix(chart: chart);
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final neutral = chart['better'] == 'none';     // a description of data, not a contest
    final unit = '${chart['unit'] ?? ''}';
    final rows = <(String, num, bool, bool)>[];   // label, value, ours, first in a group
    final series = (chart['series'] as List?)?.cast<String>();
    if (series != null) {
      for (final g in _list(chart['groups'])) {
        final values = (g['values'] as List).cast<num>();
        for (var i = 0; i < values.length; i++) {
          rows.add(('${g['label']} · ${series[i]}', values[i], i == values.length - 1, i == 0));
        }
      }
    } else {
      for (final b in _list(chart['bars'])) {
        rows.add(('${b['label']}', b['value'] as num, b['ours'] == true, false));
      }
    }
    final top = rows.fold<num>(0, (a, r) => r.$2 > a ? r.$2 : a);
    return Semantics(
      label: '${chart['title']}: ${rows.map((r) => '${r.$1} ${fmt(r.$2, unit)}').join(', ')}',
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${chart['title']}', style: theme.textTheme.titleMedium),
        if (!neutral)
          Text(chart['better'] == 'lower' ? 'Lower is better' : 'Higher is better',
              style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 10),
        for (final r in rows)
          Padding(
            padding: EdgeInsets.only(top: r.$4 ? 10 : 0, bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(r.$1, style: theme.textTheme.bodyMedium)),
                Text(fmt(r.$2, unit), style: TextStyle(fontWeight: r.$3 ? FontWeight.w700 : FontWeight.w500)),
              ]),
              const SizedBox(height: 4),
              LayoutBuilder(builder: (context, box) {
                final w = top <= 0 ? 0.0 : box.maxWidth * (r.$2 / top);
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: r.$2 > 0 ? w.clamp(6.0, box.maxWidth) : 6.0,
                    height: 14,
                    decoration: BoxDecoration(
                      color: r.$3 ? c.lime : (neutral ? theme.colorScheme.onSurface.withValues(alpha: 0.55) : c.range),
                      borderRadius: BorderRadius.circular(7),
                      border: r.$3 ? Border.all(color: c.onLime.withValues(alpha: 0.15)) : null,
                    ),
                  ),
                );
              }),
            ]),
          ),
      ]),
    );
  }
}

/// A confusion matrix: true state down, predicted across. Each cell is shaded by the share of its row, so the
/// diagonal (right answers) stands out; Stable called Critical sits in the far corner.
class _Matrix extends StatelessWidget {
  const _Matrix({required this.chart});
  final Map<String, dynamic> chart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final labels = (chart['labels'] as List).cast<String>();
    final rows = (chart['rows'] as List).map((r) => (r as List).cast<num>()).toList();
    final total = rows.fold<num>(0, (a, r) => a + r.fold<num>(0, (x, y) => x + y));
    var right = 0.0;
    for (var i = 0; i < rows.length; i++) {
      right += rows[i][i].toDouble();
    }
    Widget cell(String text, {Color? bg, bool bold = false, Color? fg}) => Container(
          height: 46,
          margin: const EdgeInsets.all(2),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Text(text, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: fg)),
        );
    return Semantics(
      label: '${chart['title']}. ${[
        for (var i = 0; i < rows.length; i++)
          'True ${labels[i]}: ${[for (var j = 0; j < rows[i].length; j++) '${rows[i][j]} called ${labels[j]}'].join(', ')}'
      ].join('. ')}',
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${chart['title']}', style: theme.textTheme.titleMedium),
        Text('${(right / (total == 0 ? 1 : total) * 100).toStringAsFixed(1)}% on the diagonal (right)',
            style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 10),
        Table(
          columnWidths: const {0: FlexColumnWidth(1.3)},
          children: [
            TableRow(children: [
              const SizedBox(),
              for (final l in labels) cell(l, bold: true),
            ]),
            for (var i = 0; i < rows.length; i++)
              TableRow(children: [
                Align(alignment: Alignment.centerLeft, child: Text(labels[i], style: const TextStyle(fontWeight: FontWeight.w600))),
                for (var j = 0; j < rows[i].length; j++)
                  () {
                    final rowSum = rows[i].fold<num>(0, (a, b) => a + b);
                    final share = rowSum == 0 ? 0.0 : rows[i][j] / rowSum;
                    final diag = i == j;
                    return cell('${rows[i][j]}',
                        bold: diag,
                        bg: diag
                            ? c.lime.withValues(alpha: 0.25 + 0.75 * share)
                            : c.warnBg.withValues(alpha: share < 0.02 ? 0.25 : 0.4 + 0.6 * share),
                        fg: diag ? c.onLime : null);
                  }(),
              ]),
          ],
        ),
      ]),
    );
  }
}

/// The scorecard at the top of Models: one line per model, its headline measure against what it replaced.
class _Scorecard extends StatelessWidget {
  const _Scorecard({required this.models});
  final List<Map<String, dynamic>> models;

  static String _fmt(num v, String unit) {
    if (unit == 'KES') return 'KES ${money(v)}';
    if (unit == '%') return '${v.round()}%';
    if (v != 0 && v.abs() < 0.001) return v.toStringAsExponential(1);
    return v == v.roundToDouble() && v.abs() >= 1 ? '${v.round()}' : '$v';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final rows = models.where((m) => m['headline'] != null).toList();
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Scorecard', style: theme.textTheme.titleLarge),
        Text('Each deployed model against the method it replaced or its baseline, on held-out data.',
            style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(height: 12),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 22),
          () {
            final m = rows[i];
            final h = (m['headline'] as Map).cast<String, dynamic>();
            final unit = '${h['unit'] ?? ''}';
            final b = h['baseline'] as num, o = h['ours'] as num;
            final lower = h['better'] == 'lower';
            final won = lower ? o < b : o > b;
            String? pct;
            if ((b.abs() >= 0.01 && o.abs() >= 0.01) || (o == 0 && b > 0)) {
              final p = (lower ? (b - o) / b : (o - b) / b) * 100;
              pct = '${p.abs() >= 10 ? p.round() : p.toStringAsFixed(1)}% ${p >= 0 ? 'better' : 'worse'}';
            }
            return Wrap(
              spacing: 16,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 220, maxWidth: 380),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${m['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('${h['measure']}', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                  ]),
                ),
                Text.rich(TextSpan(children: [
                  TextSpan(text: '${h['baseline_label']} ${_fmt(b, unit)}  →  ', style: TextStyle(color: c.muted)),
                  TextSpan(text: _fmt(o, unit), style: const TextStyle(fontWeight: FontWeight.w700)),
                ])),
                _Chip(pct ?? (won ? 'Passes' : 'Check'), strong: won),
              ],
            );
          }(),
        ],
      ]),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({required this.t});
  final Map<String, dynamic> t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cols = (t['columns'] as List).cast<String>();
    final rows = (t['rows'] as List).cast<List>();
    Widget cell(Object v, {bool head = false, bool first = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(v is num ? v.toStringAsFixed(3) : '$v',
              textAlign: first ? TextAlign.left : TextAlign.right,
              style: head || first ? const TextStyle(fontWeight: FontWeight.w600) : null),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${t['title']}', style: theme.textTheme.titleMedium),
      const SizedBox(height: 6),
      Table(
        columnWidths: const {0: FlexColumnWidth(1.4)},
        children: [
          TableRow(children: [for (var i = 0; i < cols.length; i++) cell(cols[i], head: true, first: i == 0)]),
          for (final r in rows) TableRow(children: [for (var i = 0; i < r.length; i++) cell(r[i] as Object, first: i == 0)]),
        ],
      ),
    ]);
  }
}

// ---------------- Forecast on real months ----------------

/// The forecast on people's real months: kept before each month began, compared once it was over.
List<Widget> _realMonths(BuildContext context, Map<String, dynamic>? d) {
  final theme = Theme.of(context);
  final c = AppColors.of(context);
  const intro = _Heading('The forecast on people\'s real months',
      sub: 'Each forecast is kept when it is made, before the month starts, and compared with what was really '
          'spent once the month is over. Only the pooled error is shown, never anyone\'s figures.');
  if (d == null) {
    return [
      intro,
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('No finished months yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('A month counts once a user has records for the whole month and a forecast was kept before it '
              'began. The numbers appear here as volunteers use the app.',
              style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
        ]),
      ),
    ];
  }
  final inside = ((d['inside_range'] as num) * 100).round();
  return [
    intro,
    CardRow(minWidth: 180, children: [
      _Tile('${d['months']}', 'Months checked'),
      _Tile('${d['users']}', 'People'),
      _Tile('$inside%', 'Inside the 80% range'),
    ]),
    Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        BarChartCard(chart: {
          'title': 'Average error, next month (KES)', 'unit': 'KES', 'better': 'lower',
          'bars': [
            {'label': 'Synthetic test households', 'value': 9967},
            {'label': 'Real months', 'value': d['mae_KES'], 'ours': true},
          ],
        }),
        const SizedBox(height: 22),
        BarChartCard(chart: {
          'title': 'Months inside the 80% range', 'unit': '%', 'better': 'higher',
          'bars': [
            {'label': 'Synthetic test households', 'value': 83},
            {'label': 'Real months', 'value': inside, 'ours': true},
          ],
        }),
        const SizedBox(height: 10),
        Text('WAPE ${d['wape']}. A few months move these numbers a lot; read them with the count above.',
            style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
      ]),
    ),
  ];
}

// ---------------- Real use ----------------

/// Evidence from people using the app, pooled with no names: how they rate the outputs (deviation D16), how
/// much of the statement reader's sorting they kept (audit A-14), the forecast on their real months, and what
/// they use.
class _RealUsePage extends StatelessWidget {
  const _RealUsePage({required this.v, required this.real});
  final Map<String, dynamic> v;
  final Map<String, dynamic>? real;

  static const _scale = ['1 Not at all', '2', '3', '4', '5 Exactly'];
  static const _presetNames = {
    'purchase': 'A purchase', 'loan': 'A loan', 'move': 'Moving house', 'baby': 'A new baby',
    'savings_goal': 'A savings goal', 'income_change': 'An income change', 'plan': 'A custom plan',
    'monthly_cost': 'A new monthly cost', 'fees': 'School fees', 'house_help': 'House help',
    'family_support': 'Family support',
  };

  Widget _ratingPanel(BuildContext context, String title, Map<String, dynamic> r) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final spread = (r['spread'] as Map).cast<String, dynamic>();
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(r['mean'] == null ? 'No answers yet' : '${r['mean']} out of 5',
            style: theme.textTheme.headlineMedium),
        Text('${r['count']} answers from ${r['people']} people', style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(height: 16),
        BarChartCard(chart: {
          'title': 'How the answers spread', 'unit': '', 'better': 'none',
          'bars': [for (var i = 1; i <= 5; i++) {'label': _scale[i - 1], 'value': spread['$i'] ?? 0}],
        }),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final ratings = (v['ratings'] as Map).cast<String, dynamic>();
    final sorting = (v['sorting'] as Map?)?.cast<String, dynamic>();
    final usage = (v['usage'] as Map).cast<String, dynamic>();
    final presets = (usage['by_preset'] as Map).cast<String, dynamic>();
    final sources = (usage['records_by_source'] as Map).cast<String, dynamic>();
    String pct(num? x) => x == null ? '-' : '${(x * 100).round()}%';
    final checks = usage['checks'] as num;
    return _Scroll(children: [
      const _Heading('Does Tosha match people\'s real finances?',
          sub: 'Users answer on a 1 to 5 scale under the overview and under each affordability answer. This is '
              'the test of the reworded hypothesis (deviation D16).'),
      CardColumns(minWidth: 320, children: [
        _ratingPanel(context, 'Overview', (ratings['overview'] as Map).cast<String, dynamic>()),
        _ratingPanel(context, '"Can I afford it?" answers', (ratings['afford'] as Map).cast<String, dynamic>()),
      ]),
      const _Heading('How well statements are sorted',
          sub: 'Every payment the reader sorted by itself is counted right unless its owner changed it. Pooled '
              'over everyone\'s statements; no names or amounts per person.'),
      if (sorting == null)
        Panel(
          child: Text('No statements imported yet.', style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
        )
      else ...[
        CardRow(minWidth: 180, children: [
          _Tile(pct(sorting['precision'] as num?), 'Sorted by the reader and kept'),
          _Tile(pct(sorting['auto_share_by_money'] as num?), 'Of the money sorted with no help'),
          _Tile('${sorting['payments']}', 'Payments from ${sorting['people']} people'),
        ]),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            BarChartCard(chart: {
              'title': 'What happened to each payment', 'unit': '', 'better': 'none',
              'bars': [
                {'label': 'Sorted by the reader, kept', 'value': sorting['kept']},
                {'label': 'Sorted by the reader, changed by the user', 'value': sorting['corrected']},
                {'label': 'Left unsorted, then sorted by the user', 'value': sorting['sorted_by_user']},
                {'label': 'Still unsorted', 'value': sorting['still_unsorted']},
              ],
            }),
            const SizedBox(height: 10),
            Text(
                'Kept is an upper bound: a payment nobody checked counts as right. On the developer\'s own statement '
                '41-43% of the money was sorted before any tagging, and 89% after tagging the top 10 payees '
                '(experiments, 4 Nov).',
                style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
          ]),
        ),
      ],
      ..._realMonths(context, real),
      const _Heading('What people use'),
      CardRow(minWidth: 180, children: [
        _Tile('$checks', 'Affordability checks'),
        _Tile('${usage['people_checking']}', 'People who checked'),
        _Tile(checks == 0 ? '-' : '${((usage['applied'] as num) / checks * 100).round()}%',
            'Checks followed by "I\'m doing this"'),
        _Tile('${usage['ratings']}', 'Ratings given'),
      ]),
      if (v['budgets'] != null)
        CardRow(minWidth: 180, children: [
          _Tile((v['budgets'] as Map)['share_kept'] == null ? '-'
              : '${(((v['budgets'] as Map)['share_kept'] as num) * 100).round()}%', 'Budget lines kept'),
          _Tile('${(v['budgets'] as Map)['months']}', 'Past months with a budget'),
          _Tile('${(v['budgets'] as Map)['kept']} of ${(v['budgets'] as Map)['lines']}', 'Everyday lines kept'),
        ]),
      if (presets.isNotEmpty || sources.isNotEmpty)
        Panel(
          child: LayoutBuilder(builder: (context, box) {
            final charts = [
              if (presets.isNotEmpty)
                {'title': 'Checks by kind', 'unit': '', 'better': 'none',
                 'bars': [for (final e in presets.entries) {'label': _presetNames[e.key] ?? e.key, 'value': e.value}]},
              if (sources.isNotEmpty)
                {'title': 'Records by how they came in', 'unit': '', 'better': 'none',
                 'bars': [
                   for (final e in sources.entries)
                     {'label': switch (e.key) { 'mpesa' => 'M-PESA statement', 'manual' => 'Typed in', 'messages' => 'Pasted messages', _ => e.key }, 'value': e.value}
                 ]},
            ];
            final cols = box.maxWidth >= 640 ? charts.length : 1;
            final w = (box.maxWidth - 28 * (cols - 1)) / cols;
            return Wrap(spacing: 28, runSpacing: 22, children: [
              for (final ch in charts) SizedBox(width: w, child: BarChartCard(chart: ch)),
            ]);
          }),
        ),
    ]);
  }
}

// ---------------- Performance and logs ----------------

class _PerformancePage extends StatelessWidget {
  const _PerformancePage({required this.p});
  final Map<String, dynamic> p;

  static String _when(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.day} ${monthShort[t.month - 1]}, ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final routes = _list(p['routes']);
    final events = _list(p['events']);
    final db = p['db_round_trip_ms'] as num;
    final rate = p['error_rate'] as num?;
    final share = p['db_share'] as num?;
    return _Scroll(children: [
      _Heading('Since the server started, ${_when('${p['since']}')}',
          sub: 'The last 1,000 requests, kept in memory. Only the address pattern is kept: no user, email or amount.'),
      CardRow(minWidth: 180, children: [
        _Tile('${p['requests']}', 'Requests'),
        _Tile(p['median_ms'] == null ? '-' : '${p['median_ms']} ms', 'Typical response'),
        _Tile(p['p95_ms'] == null ? '-' : '${p['p95_ms']} ms', 'Slowest 5% take longer than'),
        _Tile(rate == null ? '-' : '${(rate * 100).toStringAsFixed(1)}%', 'Server errors'),
      ]),
      Panel(
        color: db < 20 ? null : c.warnBg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const _Heading('Database'),
          const SizedBox(height: 8),
          _Line('Round trip to the database now', '$db ms', ok: db < 20),
          if (share != null) _Line('Share of response time spent in the database', '${(share * 100).round()}%'),
          const SizedBox(height: 6),
          Text(
              db < 20
                  ? 'The database is close to the server, so the number of queries per screen matters little.'
                  : 'Each query travels this far. Over 20 ms usually means the server and the database are in '
                      'different regions; moving one next to the other is the biggest speed-up.',
              style: theme.textTheme.bodyMedium?.copyWith(color: db < 20 ? c.muted : c.warn)),
        ]),
      ),
      if (routes.isNotEmpty)
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            BarChartCard(chart: {
              'title': 'Typical response by screen (ms)', 'unit': 'ms', 'better': 'lower',
              'bars': [
                for (final r in routes.take(8)) {'label': '${r['method']} ${r['route']}', 'value': r['median_ms']},
              ],
            }),
            const SizedBox(height: 18),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 22,
                headingTextStyle: const TextStyle(fontWeight: FontWeight.w600),
                columns: const [
                  DataColumn(label: Text('Address')),
                  DataColumn(label: Text('Calls'), numeric: true),
                  DataColumn(label: Text('Typical ms'), numeric: true),
                  DataColumn(label: Text('Slowest 5%'), numeric: true),
                  DataColumn(label: Text('Database ms'), numeric: true),
                  DataColumn(label: Text('Queries'), numeric: true),
                  DataColumn(label: Text('Errors'), numeric: true),
                ],
                rows: [
                  for (final r in routes)
                    DataRow(cells: [
                      DataCell(Text('${r['method']} ${r['route']}')),
                      DataCell(Text('${r['count']}')),
                      DataCell(Text('${r['median_ms']}')),
                      DataCell(Text('${r['p95_ms']}')),
                      DataCell(Text('${r['median_db_ms']}')),
                      DataCell(Text('${r['median_queries']}')),
                      DataCell(Text('${r['errors']}')),
                    ]),
                ],
              ),
            ),
          ]),
        ),
      const _Heading('Recent events', sub: 'Sign-ups, imports, failed log-ins, limits reached and server errors.'),
      Panel(
        child: events.isEmpty
            ? const Text('Nothing yet since the server started.')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < events.length && i < 50; i++) ...[
                  if (i > 0) const Divider(height: 18),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(
                        switch ('${events[i]['kind']}') {
                          'error' => Icons.error_rounded,
                          'security' => Icons.shield_rounded,
                          'data' => Icons.upload_file_rounded,
                          _ => Icons.person_rounded,
                        },
                        size: 20,
                        color: events[i]['kind'] == 'error' ? c.warn : null),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${events[i]['text']}')),
                    Text(_when('${events[i]['at']}'), style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                  ]),
                ],
              ]),
      ),
      Text('Full server logs stay on the hosting dashboard (Render). These figures reset when the server restarts.',
          style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
    ]);
  }
}

// ---------------- Datasets ----------------

class _DatasetsPage extends StatelessWidget {
  const _DatasetsPage({required this.sets});
  final List<Map<String, dynamic>> sets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return _Scroll(children: [
      const _Heading('What the models learned from',
          sub: 'Synthetic data is labelled as synthetic everywhere. Real data is only the developer\'s statement and '
              'users\' own records, with consent.'),
      for (final s in sets)
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('${s['name']}', style: theme.textTheme.titleLarge)),
              _Chip('${s['kind']}', strong: '${s['kind']}'.startsWith('Real')),
            ]),
            const SizedBox(height: 6),
            Text('${s['what']}', style: theme.textTheme.bodyLarge),
            const SizedBox(height: 10),
            _Line('Size', '${s['size']}'),
            _Line('Used for', '${s['used_for']}'),
            if (s['charts'] != null) ...[
              const SizedBox(height: 14),
              LayoutBuilder(builder: (context, box) {
                final charts = _list(s['charts']);
                final cols = ((box.maxWidth + 28) / (240 + 28)).floor().clamp(1, charts.length);
                final w = (box.maxWidth - 28 * (cols - 1)) / cols;
                return Wrap(spacing: 28, runSpacing: 22, children: [
                  for (final ch in charts) SizedBox(width: w, child: BarChartCard(chart: ch)),
                ]);
              }),
            ],
            for (final f in (s['facts'] as List? ?? const []).cast<String>())
              Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $f', style: theme.textTheme.bodyMedium)),
            if (s['limit'] != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(16)),
                child: Text('Limit: ${s['limit']}', style: theme.textTheme.bodyMedium?.copyWith(color: c.warn)),
              ),
            ],
          ]),
        ),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Changing the data and retraining', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('The synthetic dataset is rebuilt by the versioned scripts in data_generation/, and each model is '
              'retrained by its script in scripts/ with a held-out check, then committed. Every deployed model '
              'can be reproduced, and an untested model never goes live from a button on the server '
              '(deviation D11). The date of each model file is on the Models page.',
              style: theme.textTheme.bodyLarge?.copyWith(color: c.muted)),
        ]),
      ),
    ]);
  }
}

// ---------------- Users ----------------

class _UsersPage extends StatelessWidget {
  const _UsersPage({required this.users, required this.total, required this.actions, required this.onChanged});
  final List<Map<String, dynamic>> users;
  final int total;
  final List<Map<String, dynamic>> actions;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);

    Future<void> remove(Map<String, dynamic> u) async {
      final yes = await showChoiceSheet<bool>(
        context,
        title: 'Delete ${u['email']}?',
        message: 'This removes the account and everything kept about it: household, records, plans and checks. '
            'It cannot be undone.',
        choices: const [SheetChoice('Delete the account', true, primary: true)],
      );
      if (yes != true || !context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        await context.read<AppState>().api.adminDeleteUser(u['id'] as int);
        messenger.showSnackBar(const SnackBar(content: Text('Account deleted')));
        await onChanged();
      } on ApiException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    }

    Future<void> pause(Map<String, dynamic> u) async {
      final blocked = u['blocked'] == true;
      final yes = await showChoiceSheet<bool>(
        context,
        title: blocked ? 'Let ${u['email']} back in?' : 'Pause ${u['email']}?',
        message: blocked
            ? 'They can log in and use Tosha again. Nothing was deleted while the account was paused.'
            : 'They are logged out and cannot log in until you let them back in. Their data is kept.',
        choices: [SheetChoice(blocked ? 'Let them back in' : 'Pause the account', true, primary: true)],
      );
      if (yes != true || !context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        await context.read<AppState>().api.adminBlockUser(u['id'] as int, !blocked);
        messenger.showSnackBar(SnackBar(content: Text(blocked ? 'Account let back in' : 'Account paused')));
        await onChanged();
      } on ApiException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    }

    const actionWords = {'delete': 'Deleted', 'block': 'Paused', 'unblock': 'Let back in'};
    return _Scroll(children: [
      _Heading('Accounts',
          sub: 'Masked emails and counts only. No one\'s spending, income or payees are shown. '
              '${total > users.length ? 'Newest ${users.length} of $total.' : ''}'),
      Panel(
        child: users.isEmpty
            ? const Text('No accounts yet.')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < users.length; i++) ...[
                  if (i > 0) const Divider(height: 20),
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Text('${users[i]['email']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (users[i]['admin'] == true) const _Chip('Admin', strong: true),
                          if (users[i]['blocked'] == true) const _Chip('Paused'),
                        ]),
                        Text('Joined ${users[i]['joined']}', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                      ]),
                    ),
                    Text(
                      [
                        '${users[i]['records']} records',
                        '${users[i]['checks']} checks',
                        if (users[i]['statement'] == true) 'statement',
                        if (users[i]['household'] != true) 'no household',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (users[i]['admin'] != true) ...[
                      IconButton(
                        tooltip: users[i]['blocked'] == true ? 'Let this account back in' : 'Pause this account',
                        onPressed: () => pause(users[i]),
                        icon: Icon(users[i]['blocked'] == true ? Icons.lock_open_rounded : Icons.block_rounded),
                      ),
                      IconButton(
                        tooltip: 'Delete this account',
                        onPressed: () => remove(users[i]),
                        icon: Icon(Icons.delete_rounded, color: c.warn),
                      ),
                    ],
                  ]),
                ],
              ]),
      ),
      const _Heading('Admin actions',
          sub: 'A permanent record of accounts paused, let back in or deleted. Account numbers only, never emails.'),
      Panel(
        child: actions.isEmpty
            ? const Text('No admin actions yet.')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const Divider(height: 18),
                  Row(children: [
                    Expanded(
                        child: Text('${actionWords[actions[i]['action']] ?? actions[i]['action']} '
                            'account ${actions[i]['account']}')),
                    Text('${actions[i]['at']}'.replaceFirst('T', ' '),
                        style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
                  ]),
                ],
              ]),
      ),
    ]);
  }
}

// ---------------- Settings ----------------

class _SettingsPage extends StatelessWidget {
  const _SettingsPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themes = context.watch<ThemeController>();
    final state = context.read<AppState>();

    Future<void> logOut() async {
      final everywhere = await showChoiceSheet<bool>(
        context,
        title: 'Log out?',
        message: 'You will need the admin email and password to come back.',
        choices: const [SheetChoice('Log out', false, primary: true), SheetChoice('Log out on all devices', true)],
      );
      if (everywhere != null && context.mounted) await context.read<AppState>().logOut(everywhere: everywhere);
    }

    return _Scroll(children: [
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Appearance', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
            ],
            selected: {themes.mode},
            onSelectionChanged: (s) => context.read<ThemeController>().set(s.first),
          ),
        ]),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.lock_rounded),
          title: const Text('Privacy notice'),
          subtitle: const Text('What users agree to'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showPrivacy(context, state.api),
        ),
      ),
      Text('Who is an admin is set on the server (ADMIN_EMAILS), never in the app.',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).muted)),
      FilledButton(onPressed: logOut, child: const Text('Log out')),
    ]);
  }
}
