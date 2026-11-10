import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Colours of the three verdicts: Affordable lime, Stretch amber, Not affordable brown.
(Color bg, Color fg) verdictColors(BuildContext context, String verdict) {
  final c = AppColors.of(context);
  return switch (verdict) {
    'Affordable' => (c.lime, const Color(0xFF111111)),
    'Stretch' => (c.warnBg, c.warn),
    _ => (const Color(0xFF7A3E00), Colors.white),
  };
}

/// The verdict as a small coloured label.
class VerdictChip extends StatelessWidget {
  const VerdictChip(this.verdict, {super.key, this.large = false});
  final String verdict;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = verdictColors(context, verdict);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 16 : 10, vertical: large ? 6 : 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(large ? 18 : 12)),
      child: Text(verdict,
          style: TextStyle(fontFamily: 'PlusJakartaSans', color: fg, fontWeight: FontWeight.w700, fontSize: large ? 22 : 13)),
    );
  }
}

/// The 0-100 score on the verdict bands (Not affordable below 33, Stretch 33-55, Affordable 56+), with a marker.
class ScoreScale extends StatelessWidget {
  const ScoreScale({super.key, required this.score, this.before});
  final num score;
  final num? before;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: c.muted);
    return Semantics(
      label: 'Score $score on a scale where below 33 is not affordable, 33 to 55 is a stretch and 56 or more is affordable.',
      child: ExcludeSemantics(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LayoutBuilder(builder: (context, box) {
            Widget mark(num at, double opacity) => Positioned(
                  left: (box.maxWidth * (at.clamp(0, 100) / 100) - 2).clamp(0, box.maxWidth - 4).toDouble(),
                  top: 0,
                  child: Opacity(
                    opacity: opacity,
                    child: Container(width: 4, height: 22, decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurface, borderRadius: BorderRadius.circular(2))),
                  ),
                );
            return SizedBox(
              height: 22,
              child: Stack(children: [
                Positioned.fill(
                  top: 5,
                  bottom: 5,
                  child: Row(children: [
                    Expanded(flex: 33, child: Container(decoration: BoxDecoration(color: c.critical,
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(6))))),
                    const SizedBox(width: 3),
                    Expanded(flex: 23, child: Container(color: c.strained)),
                    const SizedBox(width: 3),
                    Expanded(flex: 44, child: Container(decoration: BoxDecoration(color: c.stable,
                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6))))),
                  ]),
                ),
                if (before != null && before != score) mark(before!, 0.3),
                mark(score, 1),
              ]),
            );
          }),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(flex: 33, child: Text('0 · Not affordable', style: muted)),
            Expanded(flex: 23, child: Text('Stretch', style: muted)),
            Expanded(flex: 44, child: Text('Affordable · 100', style: muted, textAlign: TextAlign.right)),
          ]),
        ]),
      ),
    );
  }
}
