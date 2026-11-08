import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/transaction.dart' show categoryLabel;
import '../theme/app_theme.dart';
import 'format.dart';

/// Chart colours. Each category keeps its own colour on every screen and in every month (colour follows the
/// thing, never its rank). Six hues from a palette checked for colour-blind separation in light and dark mode;
/// every chart also writes its labels and amounts, so nothing depends on colour alone.
class ChartColors {
  static const _light = [Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), Color(0xFFEDA100),
    Color(0xFFE87BA4), Color(0xFF008300)];
  static const _dark = [Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70), Color(0xFFC98500),
    Color(0xFFD55181), Color(0xFF008300)];

  static const _slot = {
    'food_groceries': 0, 'transport': 1, 'airtime_data': 2, 'utilities': 3, 'mobile_money_transfers': 4,
    'entertainment': 5,
  };

  static bool _isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

  /// A slot 0-5 of the palette.
  static Color slot(BuildContext c, int i) => (_isDark(c) ? _dark : _light)[i];

  /// Everything outside the six everyday categories (rent, fees, shopping, "Other"...) is a neutral grey.
  static Color other(BuildContext c) => _isDark(c) ? const Color(0xFF6E6E68) : const Color(0xFFB8B8B1);

  static Color category(BuildContext c, String key) {
    final i = _slot[key];
    return i == null ? other(c) : slot(c, i);
  }
}

class Slice {
  const Slice(this.label, this.value, this.color);
  final String label;
  final double value;
  final Color color;
}

/// Spending by category as at most [maxSlices] slices: the biggest ones, then the rest as "Other".
List<Slice> categorySlices(BuildContext context, Map<String, num> byCategory, {int maxSlices = 6}) {
  final items = byCategory.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
  final top = items.take(maxSlices - 1).toList();
  final rest = items.skip(maxSlices - 1).fold<double>(0, (a, e) => a + e.value);
  return [
    for (final e in top) Slice(categoryLabel(e.key), e.value.toDouble(), ChartColors.category(context, e.key)),
    if (rest > 0) Slice('Other', rest, ChartColors.other(context)),
  ];
}

/// A donut for "parts of one whole" (where a month's money went, how a budget is split). The total sits in the
/// middle; the legend beside it gives every part's amount and share, so the slices never have to be compared by eye.
class DonutWithLegend extends StatelessWidget {
  const DonutWithLegend({super.key, required this.slices, required this.centerLabel, this.size = 168});
  final List<Slice> slices;
  final String centerLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final total = slices.fold<double>(0, (a, s) => a + s.value);
    final donut = Semantics(
      label: '$centerLabel: ${slices.map((s) => '${s.label} ${kesAmount(s.value)}').join(', ')}',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _DonutPainter(slices, theme.colorScheme.surface),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(money(total), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              Text(centerLabel, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
            ]),
          ),
        ),
      ),
    );
    final legend = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final s in slices)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 10),
            Expanded(child: Text(s.label)),
            Text(kesAmount(s.value), style: const TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(
              width: 48,
              child: Text(total == 0 ? '' : '${(s.value / total * 100).round()}%',
                  textAlign: TextAlign.right, style: TextStyle(color: c.muted)),
            ),
          ]),
        ),
    ]);
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 420) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: donut),
          const SizedBox(height: 16),
          legend,
        ]);
      }
      return Row(children: [donut, const SizedBox(width: 28), Expanded(child: legend)]);
    });
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.slices, this.surface);
  final List<Slice> slices;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<double>(0, (a, s) => a + s.value);
    const stroke = 22.0;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.shortestSide / 2 - stroke / 2);
    if (total <= 0) {
      canvas.drawArc(rect, 0, math.pi * 2, false,
          Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..color = surface.withValues(alpha: 0.5));
      return;
    }
    // A small surface-coloured gap between parts, so neighbours never merge.
    final gap = slices.length > 1 ? 2 / (rect.width / 2) : 0.0;
    var start = -math.pi / 2;
    for (final s in slices) {
      final sweep = s.value / total * math.pi * 2;
      if (sweep > gap) {
        canvas.drawArc(rect, start + gap / 2, sweep - gap, false,
            Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..color = s.color);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.slices != slices || old.surface != surface;
}

/// A bar of spent against a limit, with a thin mark for where spending should be by today (the pace). Amber
/// when ahead of pace, the warning colour when over.
class PaceBar extends StatelessWidget {
  const PaceBar({super.key, required this.spent, required this.limit, required this.pace, required this.color});
  final double spent;
  final double limit;
  final double pace;      // 0..1, share of the month gone
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final share = limit <= 0 ? (spent > 0 ? 1.0 : 0.0) : (spent / limit).clamp(0.0, 1.0);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return SizedBox(
        height: 14,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(decoration: BoxDecoration(color: c.range, borderRadius: BorderRadius.circular(7))),
          Container(
            width: math.max(share * w, spent > 0 ? 6 : 0),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
          ),
          Positioned(
            left: (pace.clamp(0.0, 1.0) * w - 1).clamp(0.0, w - 2),
            top: -3,
            bottom: -3,
            child: Container(width: 2, color: Theme.of(context).colorScheme.onSurface),
          ),
        ]),
      );
    });
  }
}
