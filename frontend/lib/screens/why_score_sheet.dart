import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api.dart';
import '../state/app_state.dart';

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
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
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
    final now = (data['now'] as Map).cast<String, dynamic>();
    final after = data['after'] is Map ? (data['after'] as Map).cast<String, dynamic>() : null;
    final record = (data['track_record'] as Map?)?.cast<String, dynamic>();
    final shown = after ?? now;
    final parts = _parts(shown['parts']);
    final biggest = parts.fold<double>(1, (m, p) => (p['points'] as num).abs() > m ? (p['points'] as num).abs().toDouble() : m);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text(after == null ? 'Why your score is ${now['score']}' : 'Why the score would be ${after['score']}',
            style: theme.textTheme.titleLarge),
        if (data['title'] != null) Text(data['title'] as String, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Text('A typical household scores ${shown['typical_score']}. These parts move your score up or down from there:',
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        ...parts.map((p) => _PartBar(label: p['label'] as String, points: (p['points'] as num).toDouble(), max: biggest)),
        if (after != null) ...[
          const SizedBox(height: 16),
          Text('What this choice changes', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('From ${now['score']} today to ${after['score']}:', style: theme.textTheme.bodySmall),
          ..._parts(data['moved']).where((p) => (p['points'] as num).abs() >= 0.5).map((p) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(child: Text(p['label'] as String)),
                  Text('${(p['points'] as num) > 0 ? '+' : ''}${(p['points'] as num).round()} points',
                      style: TextStyle(fontWeight: FontWeight.w600,
                          color: (p['points'] as num) < 0 ? theme.colorScheme.error : Colors.green.shade700)),
                ]),
              )),
        ],
        if (record != null && (record['months'] as num) >= 2) ...[
          const SizedBox(height: 16),
          Text('Your track record', style: theme.textTheme.titleMedium),
          Text('You spent more than came in during ${record['overspent_months']} of the last ${record['months']} '
              'months.${record['fragile'] == true ? ' The score looks mostly at your last 3 to 6 months, so keep a buffer '
                  'until the calmer months last.' : ''}'),
        ],
        const SizedBox(height: 16),
        Text((data['note'] ?? '') as String, style: theme.textTheme.bodySmall),
        Text('Worked out on your numbers as they are today.', style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _PartBar extends StatelessWidget {
  const _PartBar({required this.label, required this.points, required this.max});
  final String label;
  final double points, max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final up = points >= 0;
    final color = up ? Colors.green.shade700 : theme.colorScheme.error;
    final share = (points.abs() / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label)),
          Text('${up ? '+' : ''}${points.round()}', style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ]),
        const SizedBox(height: 4),
        // Bars grow from the centre: left for points taken away, right for points added.
        Row(children: [
          Expanded(child: Align(alignment: Alignment.centerRight,
              child: FractionallySizedBox(widthFactor: up ? 0 : share,
                  child: Container(height: 8, color: color)))),
          Container(width: 1, height: 12, color: theme.dividerColor),
          Expanded(child: Align(alignment: Alignment.centerLeft,
              child: FractionallySizedBox(widthFactor: up ? share : 0,
                  child: Container(height: 8, color: color)))),
        ]),
      ]),
    );
  }
}
