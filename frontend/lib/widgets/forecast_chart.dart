import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'format.dart';

/// One month on the chart: what was spent (past) or what is expected, with its likely range (forecast).
class ChartMonth {
  const ChartMonth(this.label, this.value,
      {this.low, this.high, this.fees = 0, this.forecast = false, String? long})
      : long = long ?? label;
  final String label;
  final String long;
  final double value;
  final double? low;
  final double? high;
  final double fees;
  final bool forecast;
}

const _font = 'PlusJakartaSans';
const _left = 44.0, _right = 16.0;

/// Index of the month nearest to [dx] for a chart of [n] points across [width].
int _nearest(double dx, double width, int n) {
  if (n <= 1) return 0;
  final w = width - _left - _right;
  return ((dx - _left) / (w / (n - 1))).round().clamp(0, n - 1);
}

double _x(int i, int n, double width) {
  final w = width - _left - _right;
  return _left + (n == 1 ? w / 2 : w * i / (n - 1));
}

/// Hover (desktop) and tap or drag (phone) on a painted chart. Tapping the same month again closes the label.
class _Interactive extends StatefulWidget {
  const _Interactive({required this.n, required this.height, required this.painter, this.onTap});
  final int n;
  final double height;
  final CustomPainter Function(int? active) painter;
  final ValueChanged<int>? onTap;

  @override
  State<_Interactive> createState() => _InteractiveState();
}

class _InteractiveState extends State<_Interactive> {
  int? active;

  // No LayoutBuilder: the chart sits inside CardRow, which measures intrinsic heights (8 Nov crash).
  int _at(Offset p) => _nearest(p.dx, context.size?.width ?? 0, widget.n);

  @override
  Widget build(BuildContext context) => MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) {
            final i = _at(e.localPosition);
            if (i != active) setState(() => active = i);
          },
          onExit: (_) => setState(() => active = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (e) {
              final i = _at(e.localPosition);
              setState(() => active = active == i && e.kind != ui.PointerDeviceKind.mouse ? null : i);
              widget.onTap?.call(i);
            },
            onHorizontalDragUpdate: (e) {
              final i = _at(e.localPosition);
              if (i != active) setState(() => active = i);
            },
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: CustomPaint(painter: widget.painter(active)),
          ),
        ),
      );
}

/// Spending by month (25 Nov redesign): the last 3 months spent as a solid line, the next 3 expected as a dashed
/// line, each forecast month with its own likely range. Next month, the most accurate, is bold; the later two are
/// faded as rougher guesses. Hover (desktop) or tap (phone) a month for its figures.
class ForecastChart extends StatelessWidget {
  const ForecastChart(
      {super.key, required this.months, required this.income, this.height = 220, this.selected, this.onSelect,
      this.headline = true});
  final List<ChartMonth> months;
  final double income;
  final double height;
  /// A month to highlight (its index in [months]), for example the month card tapped below the chart.
  final int? selected;
  final ValueChanged<int>? onSelect;
  /// Next month in words above the chart.
  final bool headline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final next = months.where((m) => m.forecast).firstOrNull;
    final past = months.where((m) => !m.forecast).map((m) => '${m.label} ${money(m.value)}');
    final ahead = months.where((m) => m.forecast).map((m) =>
        '${m.label} about ${money(m.value)}${m.fees > 0 ? ' including school fees of ${money(m.fees)}' : ''}');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (headline && next != null) ...[
        Text('Next month', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
        const SizedBox(height: 2),
        Text('${next.long}: about ${kesAmount(next.value)}',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        if (next.low != null && next.high != null)
          Text('Likely ${money(next.low!)} to ${money(next.high!)}'
              '${next.fees > 0 ? ' · includes school fees' : ''}',
              style: theme.textTheme.bodyMedium?.copyWith(color: c.muted)),
        const SizedBox(height: 12),
      ],
      Semantics(
        label: 'Spending by month. ${past.join(', ')}. Expected: ${ahead.join(', ')}. Income ${money(income)}.',
        child: ExcludeSemantics(
          child: _Interactive(
            n: months.length,
            height: height,
            onTap: onSelect == null
                ? null
                : (i) {
                    final first = months.indexWhere((m) => m.forecast);
                    if (first >= 0 && i >= first) onSelect!(i - first);
                  },
            painter: (active) => _ChartPainter(months, income, theme, c, selected, active),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text('Hover or tap a month', style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
    ]);
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.months, this.income, this.theme, this.c, this.selected, this.active);
  final List<ChartMonth> months;
  final double income;
  final ThemeData theme;
  final AppColors c;
  final int? selected;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    if (months.isEmpty) return;
    const top = 30.0, bottom = 26.0;
    final n = months.length;
    final h = size.height - top - bottom;
    final values = [
      for (final m in months) ...[m.value, if (m.low != null) m.low!, if (m.high != null) m.high!],
      if (income > 0) income,
    ];
    var lo = values.reduce(math.min) * 0.9, hi = values.reduce(math.max) * 1.04;
    final step = _niceStep((hi - lo) / 3);
    lo = (lo / step).floor() * step;
    hi = (hi / step).ceil() * step;
    double y(double v) => top + h * (1 - (v - lo) / (hi - lo));
    double x(int i) => _x(i, n, size.width);
    final ink = theme.colorScheme.onSurface;
    final label = TextStyle(fontFamily: _font, fontSize: 12, color: c.muted);
    final firstNext = months.indexWhere((m) => m.forecast);

    // Recessive grid and amounts.
    final grid = Paint()..color = theme.colorScheme.outlineVariant.withValues(alpha: 0.6)..strokeWidth = 1;
    for (var v = lo; v <= hi + 1; v += step) {
      canvas.drawLine(Offset(_left, y(v)), Offset(size.width - _right, y(v)), grid);
      _text(canvas, compact(v), Offset(0, y(v) - 8), label);
    }

    // The month picked below the chart: a soft column.
    final sel = selected;
    if (sel != null && sel >= 0 && sel < n) {
      final half = n == 1 ? 30.0 : (size.width - _left - _right) / (n - 1) / 2.6;
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(x(sel) - half, top - 6, x(sel) + half, top + h + 6),
              const Radius.circular(12)),
          Paint()..color = c.field);
    }

    // Where the records stop and the guess begins, with a word on each side.
    if (firstNext >= 1) {
      final cut = (x(firstNext - 1) + x(firstNext)) / 2;
      _dashedLine(canvas, Offset(cut, top - 4), Offset(cut, top + h),
          Paint()..color = theme.colorScheme.outlineVariant..strokeWidth = 1.5, 4, 4);
      final spentTp = _layout('Spent', label);
      spentTp.paint(canvas, Offset(cut - spentTp.width - 8, 4));
      _text(canvas, 'Expected', Offset(cut + 8, 4), label);
    }

    // Income: a quiet reference line.
    if (income > 0) {
      _dashedLine(canvas, Offset(_left, y(income)), Offset(size.width - _right, y(income)),
          Paint()..color = c.warn.withValues(alpha: 0.8)..strokeWidth = 1.2, 3, 5);
      final tp = _layout('Income ${compact(income)}', label.copyWith(color: c.warn, fontSize: 11));
      tp.paint(canvas, Offset(size.width - _right - tp.width, y(income) - tp.height - 2));
    }

    // Each forecast month's likely range: next month bold, later months faded.
    for (var i = math.max(0, firstNext); firstNext >= 0 && i < n; i++) {
      final m = months[i];
      if (m.low == null || m.high == null) continue;
      final first = i == firstNext;
      canvas.drawLine(Offset(x(i), y(m.high!)), Offset(x(i), y(m.low!)),
          Paint()
            ..color = first ? c.lime : c.range
            ..strokeWidth = first ? 12 : 9
            ..strokeCap = StrokeCap.round);
    }

    // What was spent: a smooth solid line.
    final lastPast = firstNext < 0 ? n - 1 : firstNext - 1;
    if (lastPast >= 0) {
      final pts = [for (var i = 0; i <= lastPast; i++) Offset(x(i), y(months[i].value))];
      if (pts.length > 1) {
        canvas.drawPath(_smooth(pts), Paint()
          ..color = ink
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round);
      }
      for (final p in pts) {
        canvas.drawCircle(p, 3.5, Paint()..color = ink);
      }
    }

    // What is expected: a dashed line from the last real month, next month's point the strongest.
    if (firstNext >= 0) {
      final pts = [
        for (var i = math.max(0, firstNext - 1); i < n; i++) Offset(x(i), y(months[i].value)),
      ];
      if (pts.length > 1) {
        _dashedPath(canvas, _smooth(pts), Paint()
          ..color = c.muted
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round, 6, 6);
      }
      for (var i = firstNext; i < n; i++) {
        final p = Offset(x(i), y(months[i].value));
        if (i == firstNext) {
          canvas.drawCircle(p, 7, Paint()..color = c.lime);
          canvas.drawCircle(p, 7, Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 2.5);
        } else {
          canvas.drawCircle(p, 4.5, Paint()..color = c.muted);
        }
      }
    }

    // Month names; months with school fees get a small lime dot.
    for (var i = 0; i < n; i++) {
      final strong = i == active || i == selected || i == firstNext;
      final tp = _layout(months[i].label,
          strong ? label.copyWith(color: ink, fontWeight: FontWeight.w700) : label);
      tp.paint(canvas, Offset(x(i) - tp.width / 2, size.height - 18));
      if (months[i].fees > 0) canvas.drawCircle(Offset(x(i), size.height - 23), 3, Paint()..color = c.lime);
    }

    // The month under the pointer or finger: a guide line and its figures, pinned at the top of the chart.
    final a = active;
    if (a != null && a >= 0 && a < n) {
      canvas.drawLine(Offset(x(a), top - 4), Offset(x(a), top + h),
          Paint()..color = ink.withValues(alpha: 0.25)..strokeWidth = 1);
      final m = months[a];
      canvas.drawCircle(Offset(x(a), y(m.value)), m.forecast ? 6 : 5, Paint()..color = ink);
      final lines = <String>[
        m.forecast ? (a == firstNext ? '${m.long} · next month' : '${m.long} · rougher guess') : m.long,
        m.forecast ? 'Expected KES ${money(m.value)}' : 'You spent KES ${money(m.value)}',
        if (m.forecast && m.low != null && m.high != null) 'Likely ${compact(m.low!)} to ${compact(m.high!)}',
        if (m.fees > 0) 'Includes school fees ${compact(m.fees)}',
      ];
      _tooltip(canvas, size, x(a), lines);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.months != months || old.income != income || old.theme != theme || old.selected != selected ||
      old.active != active;
}

/// Savings month by month (25 Nov redesign): if every shilling of the budget is spent (solid) and at the usual
/// pace (dashed), with amounts, the zero line, and the 3-month cushion shaded. Hover or tap a month.
class SavingsChart extends StatelessWidget {
  const SavingsChart({super.key, required this.now, required this.path, this.cushion = 0, this.height = 170});
  final num now;
  final List<Map<String, dynamic>> path;
  final num cushion;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        label: 'Savings now ${money(now)}; at your usual pace '
            '${path.map((p) => money(p['usual_pace'] as num)).join(', ')}; if you spend your whole budget '
            '${path.map((p) => money(p['on_budget'] as num)).join(', ')}.',
        child: ExcludeSemantics(
          child: _Interactive(
            n: path.length + 1,
            height: height,
            painter: (active) => _SavingsPainter(now, path, cushion, theme, c, active),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 6, children: [
        _key(theme, c, Container(width: 16, height: 3, color: theme.colorScheme.onSurface), 'Whole budget spent'),
        _key(theme, c, Container(width: 16, height: 3, color: c.muted), 'Usual pace (dashed)'),
        if (cushion > 0)
          _key(theme, c, Container(width: 14, height: 10, decoration: BoxDecoration(color: c.field,
              borderRadius: BorderRadius.circular(3))), 'Keep: 3-month cushion'),
      ]),
    ]);
  }

  static Widget _key(ThemeData theme, AppColors c, Widget mark, String text) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        mark,
        const SizedBox(width: 6),
        Text(text, style: theme.textTheme.bodySmall?.copyWith(color: c.muted)),
      ]);
}

class _SavingsPainter extends CustomPainter {
  _SavingsPainter(this.now, this.path, this.cushion, this.theme, this.c, this.active);
  final num now;
  final List<Map<String, dynamic>> path;
  final num cushion;
  final ThemeData theme;
  final AppColors c;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 12.0, bottom = 24.0;
    final usual = [now.toDouble(), for (final p in path) (p['usual_pace'] as num).toDouble()];
    final plan = [now.toDouble(), for (final p in path) (p['on_budget'] as num).toDouble()];
    final n = usual.length;
    final all = [...usual, ...plan, 0.0, if (cushion > 0) cushion.toDouble()];
    var lo = all.reduce(math.min), hi = all.reduce(math.max) * 1.05;
    final step = _niceStep((hi - lo) / 3);
    lo = (lo / step).floor() * step;
    hi = (hi / step).ceil() * step;
    final h = size.height - top - bottom;
    double y(double v) => top + h * (1 - (v - lo) / (hi - lo));
    double x(int i) => _x(i, n, size.width);
    final ink = theme.colorScheme.onSurface;
    final label = TextStyle(fontFamily: _font, fontSize: 12, color: c.muted);

    // The cushion to keep, shaded from zero up.
    if (cushion > 0) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(_left, y(cushion.toDouble()), size.width - _right, y(0)),
              const Radius.circular(6)),
          Paint()..color = c.field);
    }
    final grid = Paint()..color = theme.colorScheme.outlineVariant.withValues(alpha: 0.6)..strokeWidth = 1;
    for (var v = lo; v <= hi + 1; v += step) {
      canvas.drawLine(Offset(_left, y(v)), Offset(size.width - _right, y(v)), grid);
      _text(canvas, compact(v), Offset(0, y(v) - 8), label);
    }
    if (lo < 0) {
      canvas.drawLine(Offset(_left, y(0)), Offset(size.width - _right, y(0)), Paint()..color = c.warn..strokeWidth = 1.2);
      _text(canvas, 'Savings run out', Offset(_left + 4, y(0) + 2), label.copyWith(color: c.warn, fontSize: 11));
    }

    final falling = usual.last < now;
    _dashedPath(canvas, _smooth([for (var i = 0; i < n; i++) Offset(x(i), y(usual[i]))]), Paint()
      ..color = falling ? c.warn : c.muted
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round, 6, 6);
    canvas.drawPath(_smooth([for (var i = 0; i < n; i++) Offset(x(i), y(plan[i]))]), Paint()
      ..color = ink
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round);
    for (var i = 0; i < n; i++) {
      canvas.drawCircle(Offset(x(i), y(plan[i])), 3.5, Paint()..color = plan[i] < 0 ? c.warn : ink);
      canvas.drawCircle(Offset(x(i), y(usual[i])), 3.5, Paint()..color = usual[i] < 0 ? c.warn : c.muted);
    }
    final names = ['Now', for (final p in path) monthShort[(p['month'] as int) - 1]];
    for (var i = 0; i < n; i++) {
      final tp = _layout(names[i], i == active ? label.copyWith(color: ink, fontWeight: FontWeight.w700) : label);
      tp.paint(canvas, Offset(x(i) - tp.width / 2, size.height - 16));
    }
    final a = active;
    if (a != null && a >= 0 && a < n) {
      canvas.drawLine(Offset(x(a), top), Offset(x(a), top + h), Paint()..color = ink.withValues(alpha: 0.25));
      _tooltip(canvas, size, x(a), a == 0
          ? ['Now', 'Savings KES ${money(now)}']
          : [
              'End of ${monthLong[(path[a - 1]['month'] as int) - 1]}',
              'Usual pace: KES ${money(usual[a])}',
              'Whole budget spent: KES ${money(plan[a])}',
            ]);
    }
  }

  @override
  bool shouldRepaint(_SavingsPainter old) =>
      old.now != now || old.path != path || old.cushion != cushion || old.theme != theme || old.active != active;
}

// ---- drawing helpers ----

double _niceStep(double raw) {
  if (raw <= 0) return 1000;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final f in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (raw <= f * mag) return f * mag;
  }
  return 10 * mag;
}

TextPainter _layout(String s, TextStyle style) =>
    TextPainter(text: TextSpan(text: s, style: style), textDirection: ui.TextDirection.ltr)..layout();

void _text(Canvas canvas, String s, Offset at, TextStyle style) => _layout(s, style).paint(canvas, at);

/// A smooth line through the points that never overshoots them (control points level with each point).
Path _smooth(List<Offset> pts) {
  final p = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i], mid = (a.dx + b.dx) / 2;
    p.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
  }
  return p;
}

void _dashedPath(Canvas canvas, Path path, Paint paint, double on, double off) {
  for (final metric in path.computeMetrics()) {
    for (var d = 0.0; d < metric.length; d += on + off) {
      canvas.drawPath(metric.extractPath(d, math.min(d + on, metric.length)), paint);
    }
  }
}

void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint, double on, double off) =>
    _dashedPath(canvas, Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy), paint..style = PaintingStyle.stroke, on, off);

/// A dark label with a few lines, pinned at the top of the chart above [atX] so a finger does not cover it.
void _tooltip(Canvas canvas, Size size, double atX, List<String> lines) {
  final tps = [
    for (var i = 0; i < lines.length; i++)
      _layout(lines[i], TextStyle(
          fontFamily: _font,
          fontSize: 12.5,
          height: 1.3,
          fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
          color: i == 0 ? Colors.white : const Color(0xFFE4E4DE))),
  ];
  const pad = 10.0;
  final w = tps.map((t) => t.width).reduce(math.max) + pad * 2;
  final h = tps.fold<double>(0, (s, t) => s + t.height) + pad * 2;
  final bx = (atX + 12 + w > size.width ? atX - 12 - w : atX + 12).clamp(0.0, math.max(0.0, size.width - w)).toDouble();
  final rect = RRect.fromRectAndRadius(Rect.fromLTWH(bx, 2, w, h), const Radius.circular(12));
  canvas.drawRRect(rect, Paint()..color = const Color(0xFF111111));
  var ty = 2 + pad;
  for (final t in tps) {
    t.paint(canvas, Offset(bx + pad, ty));
    ty += t.height;
  }
}
