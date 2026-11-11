import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Tosha's card: white (or dark) with large rounded corners and generous padding, no shadow.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.color, this.padding});
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return Container(
      padding: padding ?? EdgeInsets.all(wide ? 28 : 22),
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(28),
      ),
      child: child,
    );
  }
}

/// Cards side by side when there is room (each at least [minWidth] wide), stacked when there is not.
/// Cards in one row share the same height, as on the design canvas.
class CardRow extends StatelessWidget {
  const CardRow({super.key, required this.children, this.minWidth = 290, this.gap = 20, this.flex});
  final List<Widget> children;
  final double minWidth;
  final double gap;
  /// Optional widths relative to each other when side by side (for example [2, 1]).
  final List<int>? flex;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final fit = ((box.maxWidth + gap) / (minWidth + gap)).floor().clamp(1, children.length);
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += fit) {
          final part = children.sublist(i, (i + fit).clamp(0, children.length));
          if (fit == 1) {
            rows.add(part.first);
          } else {
            rows.add(IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var j = 0; j < part.length; j++) ...[
                  if (j > 0) SizedBox(width: gap),
                  Expanded(flex: flex != null && fit == children.length ? flex![i + j] : 1, child: part[j]),
                ],
                for (var j = part.length; j < fit; j++) ...[SizedBox(width: gap), const Expanded(child: SizedBox())],
              ]),
            ));
          }
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var r = 0; r < rows.length; r++) ...[if (r > 0) SizedBox(height: gap), rows[r]],
        ]);
      });
}

/// Cards side by side when there is room, stacked when not, each as tall as its own content. Use this instead
/// of [CardRow] for cards holding charts: CardRow makes cards equal height by measuring them first, and charts
/// that size themselves from the width they get cannot be measured that way (8 Nov: the budget page crashed).
class CardColumns extends StatelessWidget {
  const CardColumns({super.key, required this.children, this.minWidth = 290, this.gap = 20});
  final List<Widget> children;
  final double minWidth;
  final double gap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final fit = ((box.maxWidth + gap) / (minWidth + gap)).floor().clamp(1, children.length);
        if (fit == 1) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: gap), children[i]],
          ]);
        }
        final w = (box.maxWidth - gap * (fit - 1)) / fit;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final c in children) SizedBox(width: w, child: c)]);
      });
}

/// A page opened on top (forms, lists): a comfortable reading width on big screens, full width on phones.
class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child, this.maxWidth = 760});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
      );
}

/// How a [PanelTitle]'s icon is tinted: the app's lime by default, amber where the card is a caution.
enum TitleTone { lime, warn }

/// A card's heading: a circled icon, the words, and room for a control on the right. One shape for every card in
/// the app, so a heading is never just text on some screens and an icon row on others (11 Nov).
class PanelTitle extends StatelessWidget {
  const PanelTitle(this.title, {super.key, required this.icon, this.trailing, this.tone = TitleTone.lime, this.small = false});
  final String title;
  final IconData icon;
  final Widget? trailing;
  final TitleTone tone;

  /// For a card whose heading sits above a second line of its own, where titleLarge would shout.
  final bool small;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final (bg, ink) = tone == TitleTone.warn ? (c.warnBg, c.warn) : (c.lime, c.onLime);
    return Row(children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, size: 19, color: ink),
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(title, style: small ? theme.textTheme.titleMedium : theme.textTheme.titleLarge)),
      ?trailing,
    ]);
  }
}
