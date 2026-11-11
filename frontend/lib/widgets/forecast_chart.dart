import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'format.dart';

/// One month on the chart: what was spent (past) or what is expected, with its likely range (forecast).
class ChartMonth {
  const ChartMonth(this.label, this.value, {this.low, this.high, this.fees = 0, this.forecast = false});
  final String label;
  final double value;
  final double? low;
  final double? high;
  final double fees;
  final bool forecast;
}

/// Spending by month: a solid line for what was spent, a dashed line for what is expected, the likely range
/// shaded, income as a dashed amber line, and the last forecast month marked in lime with its amount.
class ForecastChart extends StatelessWidget {
  const ForecastChart({super.key, required this.months, required this.income, this.height = 240, this.selected});
  final List<ChartMonth> months;
  final double income;
  final double height;
  /// A month to highlight (its index in [months]), for example the month card tapped below the chart.
  final int? selected;

  @override
  Widget build(BuildContext context) {
    final past = months.where((m) => !m.forecast).map((m) => '${m.label} ${money(m.value)}');
    final next = months.where((m) => m.forecast).map((m) =>
        '${m.label} about ${money(m.value)}${m.fees > 0 ? ' including school fees of ${money(m.fees)}' : ''}');
    return Semantics(
      label: 'Spending by month. ${past.join(', ')}. Expected: ${next.join(', ')}. Income ${money(income)}.',
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: CustomPaint(
            size: Size.infinite,
            painter: _ChartPainter(months, income, Theme.of(context), AppColors.of(context), selected),
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.months, this.income, this.theme, this.c, this.selected);
  final List<ChartMonth> months;
  final double income;
  final ThemeData theme;
  final AppColors c;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    if (months.isEmpty) return;
    const left = 40.0, right = 12.0, top = 40.0, bottom = 28.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    final values = [
      for (final m in months) ...[m.value, if (m.low != null) m.low!, if (m.high != null) m.high!],
      if (income > 0) income,
    ];
    var lo = values.reduce(math.min) * 0.85, hi = values.reduce(math.max) * 1.05;
    final step = _niceStep((hi - lo) / 3);
    lo = (lo / step).floor() * step;
    hi = (hi / step).ceil() * step;
    double y(double v) => top + h * (1 - (v - lo) / (hi - lo));
    double x(int i) => left + (months.length == 1 ? w / 2 : w * i / (months.length - 1));
    final ink = theme.colorScheme.onSurface;
    final label = TextStyle(fontFamily: 'PlusJakartaSans', fontSize: 12, color: c.muted);

    // Grid and axis labels.
    final grid = Paint()..color = theme.colorScheme.outlineVariant..strokeWidth = 1;
    for (var v = lo; v <= hi + 1; v += step) {
      canvas.drawLine(Offset(left, y(v)), Offset(size.width - right, y(v)), grid);
      _text(canvas, compact(v), Offset(0, y(v) - 8), label);
    }

    // The highlighted month: a soft column behind everything.
    final sel = selected;
    if (sel != null && sel >= 0 && sel < months.length) {
      final half = months.length == 1 ? w / 2 : w / (months.length - 1) / 2.4;
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(x(sel) - half, top - 8, x(sel) + half, size.height - 4),
              const Radius.circular(12)),
          Paint()..color = c.field);
    }

    // Likely range for forecast months, joined to the last real month.
    final firstNext = months.indexWhere((m) => m.forecast);
    if (firstNext >= 0) {
      final start = math.max(0, firstNext - 1);
      final upper = <Offset>[], lower = <Offset>[];
      for (var i = start; i < months.length; i++) {
        final m = months[i];
        upper.add(Offset(x(i), y(m.high ?? m.value)));
        lower.add(Offset(x(i), y(m.low ?? m.value)));
      }
      final band = Path()..addPolygon([...upper, ...lower.reversed], true);
      canvas.drawPath(band, Paint()..color = c.range);
    }

    // Income.
    if (income > 0) {
      _dashed(canvas, Offset(left, y(income)), Offset(size.width - right, y(income)),
          Paint()..color = c.warn..strokeWidth = 1.5, 6, 6);
      _text(canvas, 'Income ${compact(income)}', Offset(left + 4, y(income) - 20),
          label.copyWith(color: c.warn, fontWeight: FontWeight.w600));
    }

    // What was spent, then what is expected.
    final solid = Paint()
      ..color = ink
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final lastPast = firstNext < 0 ? months.length - 1 : firstNext - 1;
    if (lastPast >= 1) {
      final p = Path()..moveTo(x(0), y(months[0].value));
      for (var i = 1; i <= lastPast; i++) {
        p.lineTo(x(i), y(months[i].value));
      }
      canvas.drawPath(p, solid);
    }
    if (firstNext >= 0) {
      final dash = Paint()..color = c.muted..strokeWidth = 2.5..strokeCap = StrokeCap.round;
      for (var i = math.max(1, firstNext); i < months.length; i++) {
        _dashed(canvas, Offset(x(i - 1), y(months[i - 1].value)), Offset(x(i), y(months[i].value)), dash, 7, 7);
      }
      final last = months.length - 1;
      final pt = Offset(x(last), y(months[last].value));
      canvas.drawCircle(pt, 7, Paint()..color = c.lime);
      canvas.drawCircle(pt, 7, Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 2.5);
      final tag = '${months[last].label} · KES ${money(months[last].value)}';
      final tp = _layout(tag, const TextStyle(
          fontFamily: 'PlusJakartaSans', fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white));
      final bw = tp.width + 24;
      final bx = (pt.dx - bw / 2).clamp(left, math.max(left, size.width - right - bw)).toDouble();
      final rect = RRect.fromRectAndRadius(Rect.fromLTWH(bx, 4, bw, 28), const Radius.circular(14));
      canvas.drawRRect(rect, Paint()..color = const Color(0xFF111111));
      tp.paint(canvas, Offset(bx + 12, 4 + (28 - tp.height) / 2));
    }

    // Where the records stop and the guess begins. Without this line the two halves of the chart read as one
    // measured series (11 Nov: testers could not tell which months had already happened).
    if (firstNext >= 1) {
      final cut = (x(firstNext - 1) + x(firstNext)) / 2;
      _dashed(canvas, Offset(cut, top), Offset(cut, top + h + 6),
          Paint()..color = theme.colorScheme.outlineVariant..strokeWidth = 1.5, 4, 4);
    }

    // Month labels; fee months get a small lime dot.
    for (var i = 0; i < months.length; i++) {
      final tp = _layout(months[i].label,
          i == selected ? label.copyWith(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w700) : label);
      tp.paint(canvas, Offset(x(i) - tp.width / 2, size.height - 18));
      if (months[i].fees > 0) canvas.drawCircle(Offset(x(i), size.height - 24), 3, Paint()..color = c.lime);
    }
  }

  static double _niceStep(double raw) {
    if (raw <= 0) return 1000;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final f in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (raw <= f * mag) return f * mag;
    }
    return 10 * mag;
  }

  static TextPainter _layout(String s, TextStyle style) =>
      TextPainter(text: TextSpan(text: s, style: style), textDirection: ui.TextDirection.ltr)..layout();

  static void _text(Canvas canvas, String s, Offset at, TextStyle style) => _layout(s, style).paint(canvas, at);

  static void _dashed(Canvas canvas, Offset a, Offset b, Paint paint, double on, double off) {
    final d = (b - a).distance;
    if (d == 0) return;
    final dir = (b - a) / d;
    for (var t = 0.0; t < d; t += on + off) {
      canvas.drawLine(a + dir * t, a + dir * math.min(t + on, d), paint);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.months != months || old.income != income || old.theme != theme || old.selected != selected;
}
