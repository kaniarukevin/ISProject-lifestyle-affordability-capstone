import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'state_words.dart';

/// The colour for a month's state. One place, so the heat map, the chips and the legend never drift apart.
Color stateColor(AppColors c, String state) =>
    switch (state) { 'Stable' => c.stable, 'Strained' => c.strained, _ => c.critical };

/// Text on a state colour: white only on the deep light-mode Critical brown, dark ink everywhere else.
Color stateInk(BuildContext context, String state) =>
    state == 'Critical' && Theme.of(context).brightness == Brightness.light
        ? Colors.white
        : const Color(0xFF111111);

/// How a month stands, shown the same way everywhere in the app: a coloured dot, the plain word, and the score
/// when there is one. A dot rather than a filled pill, because the Stable colour is the app's own lime and a lime
/// pill disappears on the lime score card (11 Nov: the same state looked different on every screen).
class StateChip extends StatelessWidget {
  const StateChip({super.key, required this.state, this.score, this.background, this.ink});
  final String state;
  final num? score;
  final Color? background;
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final s = score;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(color: background ?? c.field, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: stateColor(c, state),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0x22000000)),
          ),
        ),
        const SizedBox(width: 8),
        Text(s == null ? stateLabel(state) : '${stateLabel(state)} · ${scoreOutOf(s)}',
            style: theme.textTheme.labelLarge
                ?.copyWith(color: ink ?? theme.colorScheme.onSurface, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
