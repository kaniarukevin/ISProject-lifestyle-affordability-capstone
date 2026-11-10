import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/busy_words.dart';

/// "Why this score?" (SHAP). With no [choice] it explains the dashboard score; with a 'Can I afford it?' choice
/// it also shows the score after it and which parts moved. Loaded only when asked: each explanation takes the
/// server about half a second.
Future<void> showWhyScore(BuildContext context, {Map<String, dynamic>? choice}) {
  final api = context.read<AppState>().api;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => FutureBuilder<Map<String, dynamic>>(
        future: api.explain(choice),
        builder: (context, snap) {
          if (snap.hasError) {
            final e = snap.error;
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(e is ApiException ? e.message : 'Could not load the explanation. Try again later.'),
            );
          }
          if (!snap.hasData) return const BusyCenter(whyWords);
          return _WhyBody(data: snap.data!, controller: controller);
        },
      ),
    ),
  );
}

class _WhyBody extends StatelessWidget {
  const _WhyBody({required this.data, required this.controller});
  final Map<String, dynamic> data;
  final ScrollController controller;

  List<Map<String, dynamic>> _parts(dynamic v) => ((v as List?) ?? []).map((p) => (p as Map).cast<String, dynamic>()).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final now = (data['now'] as Map).cast<String, dynamic>();
    final after = data['after'] is Map ? (data['after'] as Map).cast<String, dynamic>() : null;
    final record = (data['track_record'] as Map?)?.cast<String, dynamic>();
    final shown = after ?? now;
    final parts = _parts(shown['parts'])..sort((a, b) => (b['points'] as num).abs().compareTo((a['points'] as num).abs()));
    final score = (shown['score'] as num).round();
    final typical = (shown['typical_score'] as num).round();
    final diff = score - typical;
    final ups = parts.where((p) => (p['points'] as num) >= 0.5).toList();
    final downs = parts.where((p) => (p['points'] as num) <= -0.5).toList();
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.muted);
    final steps = <Widget>[];
    var run = typical.toDouble();
    for (final p in parts) {
      final pts = (p['points'] as num).toDouble();
      steps.add(_Step(label: p['label'] as String, from: run, to: run + pts, value: _signed(pts)));
      run += pts;
    }

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Text(after == null ? 'Why your score is $score' : 'Why the score would be $score', style: theme.textTheme.titleLarge),
        if (data['title'] != null) Text(data['title'] as String, style: muted),
        const SizedBox(height: 16),
        // The answer first: the score against a typical household, then the biggest help and drag in one line.
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$score', style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                  diff == 0
                      ? 'The same as a typical household ($typical)'
                      : '${diff.abs()} points ${diff > 0 ? 'above' : 'below'} a typical household ($typical)',
                  style: theme.textTheme.bodyLarge),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (ups.isNotEmpty) _Lead(sign: '+', text: 'Biggest help: ${(ups.first['label'] as String).toLowerCase()}', color: _good(context)),
        if (downs.isNotEmpty) _Lead(sign: '−', text: 'Biggest drag: ${(downs.first['label'] as String).toLowerCase()}', color: c.warn),
        const SizedBox(height: 20),
        Text('From a typical household to you', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Start at the typical score. Each line adds or takes away points; together they make your score.', style: muted),
        const SizedBox(height: 14),
        // A waterfall on the 0-100 scale: each bar starts where the one above ended.
        _Step(label: 'Typical household', from: 0, to: typical.toDouble(), value: '$typical', total: true),
        ...steps,
        _Step(label: after == null ? 'Your score' : 'Score after this choice', from: 0, to: score.toDouble(), value: '$score', total: true),
        if (after != null) ...[
          const SizedBox(height: 24),
          Text('What this choice changes', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('From ${now['score']} today to ${after['score']}:', style: muted),
          const SizedBox(height: 8),
          ..._parts(data['moved']).where((p) => (p['points'] as num).abs() >= 0.5).map((p) {
            final pts = (p['points'] as num).toDouble();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(p['label'] as String)),
                Text('${_signed(pts)} points',
                    style: TextStyle(fontWeight: FontWeight.w700, color: pts < 0 ? c.warn : _good(context))),
              ]),
            );
          }),
        ],
        if (record != null && (record['months'] as num) >= 2) ...[
          const SizedBox(height: 24),
          Text('Your track record', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('You spent more than came in during ${record['overspent_months']} of the last ${record['months']} '
              'months.${((record['covered_months'] ?? 0) as num) > 0 ? ' In ${record['covered_months']} more you used money '
                  'left over from earlier months, which is fine and not counted.' : ''}'
              '${record['fragile'] == true ? ' The score looks mostly at your last 3 to 6 months, so keep a buffer '
                  'until the calmer months last.' : ''}'),
        ],
        const SizedBox(height: 24),
        Text((data['note'] ?? '') as String, style: muted),
        const SizedBox(height: 4),
        Text('Worked out on your numbers as they are today. This is an estimate from a model, not financial advice.',
            style: muted),
      ],
    );
  }

  static String _signed(double pts) {
    final r = pts.round();
    if (r == 0) return '0';
    return r > 0 ? '+$r' : '−${r.abs()}';
  }
}

/// One line of the summary: a sign in a round badge (so up and down never depend on colour alone) and the words.
class _Lead extends StatelessWidget {
  const _Lead({required this.sign, required this.text, required this.color});
  final String sign, text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Text(sign, style: TextStyle(color: Theme.of(context).colorScheme.surface, fontWeight: FontWeight.w700, height: 1)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
        ]),
      );
}

/// One bar of the waterfall, on a 0-100 track. Totals are drawn in the ink colour; parts in green (up) or amber
/// (down), with the signed points written beside them.
class _Step extends StatelessWidget {
  const _Step({required this.label, required this.from, required this.to, required this.value, this.total = false});
  final String label, value;
  final double from, to;
  final bool total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final up = to >= from;
    final zero = (to - from).abs() < 0.5 && !total;
    final color = total ? theme.colorScheme.onSurface : (zero ? theme.disabledColor : (up ? _good(context) : c.warn));
    final lo = (from < to ? from : to).clamp(0.0, 100.0) / 100;
    final hi = (from < to ? to : from).clamp(0.0, 100.0) / 100;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(label,
                style: total ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700) : theme.textTheme.bodyMedium),
          ),
          Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: total ? null : color)),
        ]),
        const SizedBox(height: 4),
        SizedBox(
          height: 10,
          child: Stack(children: [
            Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(5)))),
            if (!zero)
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: hi,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FractionallySizedBox(
                      widthFactor: hi == 0 ? 0 : ((hi - lo) / hi).clamp(0.02, 1.0),
                      child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5))),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Green for points added. The theme's "stable" lime is too pale for text and thin bars on white, so this is a
/// deeper green in light mode and a brighter one in dark mode.
Color _good(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF5BD3A0) : const Color(0xFF137A50);
