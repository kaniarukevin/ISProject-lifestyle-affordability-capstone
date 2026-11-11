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
      initialChildSize: 0.75,
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

  List<Map<String, dynamic>> _parts(dynamic v) =>
      ((v as List?) ?? []).map((p) => (p as Map).cast<String, dynamic>()).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final now = (data['now'] as Map).cast<String, dynamic>();
    final after = data['after'] is Map ? (data['after'] as Map).cast<String, dynamic>() : null;
    final record = (data['track_record'] as Map?)?.cast<String, dynamic>();
    final shown = after ?? now;
    final parts = _parts(shown['parts'])
      ..sort((a, b) => (b['points'] as num).abs().compareTo((a['points'] as num).abs()));
    final score = (shown['score'] as num).round();
    final typical = (shown['typical_score'] as num).round();
    final diff = score - typical;
    // Rows worth less than half a point are left out: a line reading "0" is noise (11 Nov).
    final ups = parts.where((p) => (p['points'] as num) >= 0.5).toList();
    final downs = parts.where((p) => (p['points'] as num) <= -0.5).toList();
    final widest = parts.isEmpty
        ? 1.0
        : parts.map((p) => (p['points'] as num).abs().toDouble()).reduce((a, b) => a > b ? a : b);
    final moved = _parts(data['moved']).where((p) => (p['points'] as num).abs() >= 0.5).toList();
    final movedWidest = moved.isEmpty
        ? 1.0
        : moved.map((p) => (p['points'] as num).abs().toDouble()).reduce((a, b) => a > b ? a : b);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: c.muted);

    return Stack(children: [
      ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 44),
        children: [
          Text(after == null ? 'Why your score is $score' : 'Why the score would be $score',
              style: theme.textTheme.titleLarge),
          if (data['title'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(data['title'] as String, style: muted),
            ),
          const SizedBox(height: 18),

          // The whole answer in one lime card: your score, and how it sits against a typical household.
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: c.lime, borderRadius: BorderRadius.circular(24)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('$score',
                    style: theme.textTheme.displaySmall
                        ?.copyWith(fontWeight: FontWeight.w700, height: 1, color: c.onLime)),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 3),
                  child: Text('/ 100',
                      style: theme.textTheme.titleMedium?.copyWith(color: c.onLime.withValues(alpha: 0.6))),
                ),
              ]),
              const SizedBox(height: 10),
              Text(
                  diff == 0
                      ? 'That is right where a typical household sits, which also scores $typical.'
                      : 'That is ${diff.abs()} point${diff.abs() == 1 ? '' : 's'} ${diff > 0 ? 'better' : 'worse'} '
                          'than a typical household, which scores $typical.',
                  style: theme.textTheme.bodyLarge?.copyWith(color: c.onLime, height: 1.35)),
            ]),
          ),

          if (ups.isNotEmpty) ...[
            const SizedBox(height: 26),
            _GroupTitle(icon: Icons.trending_up_rounded, text: "What's helping you", color: _good(context)),
            for (final p in ups)
              _Line(
                  label: p['label'] as String,
                  points: (p['points'] as num).toDouble(),
                  widest: widest,
                  up: true),
          ],
          if (downs.isNotEmpty) ...[
            const SizedBox(height: 26),
            _GroupTitle(icon: Icons.trending_down_rounded, text: "What's holding you back", color: c.warn),
            for (final p in downs)
              _Line(
                  label: p['label'] as String,
                  points: (p['points'] as num).toDouble(),
                  widest: widest,
                  up: false),
          ],

          const SizedBox(height: 18),
          Text('Every household starts at $typical. Each line above adds or takes away points, and together they '
              'make your $score.', style: muted),

          if (after != null) ...[
            const SizedBox(height: 28),
            Text('What this choice changes', style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text('From ${now['score']} today to ${after['score']}.', style: muted),
            const SizedBox(height: 10),
            for (final p in moved)
              _Line(
                  label: p['label'] as String,
                  points: (p['points'] as num).toDouble(),
                  widest: movedWidest,
                  up: (p['points'] as num) >= 0,
                  indent: false),
          ],

          if (record != null && (record['months'] as num) >= 2) ...[
            const SizedBox(height: 28),
            Text('Your track record', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
                'You spent more than came in during ${record['overspent_months']} of the last '
                '${record['months']} months.'
                '${((record['covered_months'] ?? 0) as num) > 0 ? ' In ${record['covered_months']} more you spent money left over from earlier, which does not count against you.' : ''}'
                '${record['fragile'] == true ? ' The score leans on your last few months, so keep a buffer until the calmer months last.' : ''}',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4)),
          ],

          const SizedBox(height: 26),
          Text((data['note'] ?? '') as String, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
          const SizedBox(height: 4),
          Text('Worked out on your numbers as they are today. An estimate from a model, not financial advice.',
              style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        ],
      ),
      // A fade at the bottom edge, so it is obvious there is more below (11 Nov: testers could not tell the
      // sheet scrolled).
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 32,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.surface.withValues(alpha: 0),
                  theme.colorScheme.surface,
                ],
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// "What's helping you" / "What's holding you back": a circled icon and the heading.
class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
        ]),
      );
}

/// One part of the score: what it is, how many points it is worth, and a bar showing how it compares with the
/// other parts. No axis and no running total: testers read the waterfall as a chart to decode (11 Nov).
class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.points,
    required this.widest,
    required this.up,
    this.indent = true,
  });
  final String label;
  final double points, widest;
  final bool up, indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final colour = up ? _good(context) : c.warn;
    final n = points.round().abs();
    return Padding(
      padding: EdgeInsets.only(left: indent ? 40 : 0, top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
          const SizedBox(width: 12),
          Text('${up ? '+' : '−'}$n point${n == 1 ? '' : 's'}',
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: colour)),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 8,
          child: Stack(children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(4)),
              ),
            ),
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: widest <= 0 ? 0.02 : (points.abs() / widest).clamp(0.04, 1.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(4)),
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
