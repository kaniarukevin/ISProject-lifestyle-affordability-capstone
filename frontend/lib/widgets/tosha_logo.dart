import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The Tosha mark: a lime ring, almost full ("enough, with a little left").
class ToshaLogo extends StatelessWidget {
  const ToshaLogo({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Tosha',
        image: true,
        child: CustomPaint(size: Size.square(size), painter: _RingPainter(AppColors.of(context).lime)),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.15;
    final rect = Rect.fromLTWH(stroke / 2 + size.width * 0.075, stroke / 2 + size.width * 0.075,
        size.width * 0.7, size.height * 0.7);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * 0.8, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color;
}
