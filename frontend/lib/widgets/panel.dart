import 'package:flutter/material.dart';

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
