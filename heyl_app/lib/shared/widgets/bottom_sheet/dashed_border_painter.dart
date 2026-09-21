import 'package:flutter/material.dart';

/// Paints a dashed rounded-rectangle border. Default radius 6 matches the
/// row containers in `AddToListSheet` (PROD-1861); pass a custom radius to
/// reuse for other shapes.
///
/// Dash density (3 px on / 2 px off) is calibrated to CSS `border-dashed`
/// in Figma `6353:32032` for a 1 px stroke.
class DashedBorderPainter extends CustomPainter {
  DashedBorderPainter({
    required this.color,
    this.borderRadius = 6,
    this.dashWidth = 3,
    this.dashGap = 2,
    this.strokeWidth = 1,
  });

  final Color color;
  final double borderRadius;
  final double dashWidth;
  final double dashGap;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(borderRadius),
    );
    final path = Path()..addRRect(rrect);

    final dashedPath = Path();
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final end = (distance + dashWidth).clamp(0, metric.length).toDouble();
        dashedPath.addPath(metric.extractPath(distance, end), Offset.zero);
        distance += dashWidth + dashGap;
      }
    }
    canvas.drawPath(dashedPath, paint);
  }

  @override
  bool shouldRepaint(DashedBorderPainter oldDelegate) =>
      color != oldDelegate.color ||
      borderRadius != oldDelegate.borderRadius ||
      dashWidth != oldDelegate.dashWidth ||
      dashGap != oldDelegate.dashGap ||
      strokeWidth != oldDelegate.strokeWidth;
}
