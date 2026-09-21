import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Original geometric illustrations, rendered locally without image services.
class EventArtwork extends StatelessWidget {
  const EventArtwork({super.key, required this.seed, this.height = 170});

  final int seed;
  final double height;
  static const _colours = [
    SokoColors.pink,
    SokoColors.blue,
    SokoColors.yellow,
    SokoColors.lilac,
    SokoColors.green,
  ];

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRect(
        child: CustomPaint(
          painter: _ArtworkPainter(_colours[seed % _colours.length], seed),
        ),
      ),
    ),
  );
}

class _ArtworkPainter extends CustomPainter {
  const _ArtworkPainter(this.colour, this.seed);
  final Color colour;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colour);
    final ink = Paint()..color = SokoColors.ink;
    final paper = Paint()..color = SokoColors.paper;
    final center = Offset(size.width * 0.5, size.height * 0.52);
    final radius = size.height * 0.34;
    switch (seed % 3) {
      case 0:
        for (var i = 0; i < 8; i++) {
          final angle = i * math.pi / 4;
          canvas.drawCircle(
            center + Offset(math.cos(angle), math.sin(angle)) * radius * 0.65,
            radius * 0.43,
            ink,
          );
        }
        canvas.drawCircle(center, radius * 0.38, paper);
      case 1:
        for (var i = 0; i < 4; i++) {
          final rect = Rect.fromCenter(
            center: center + Offset((i - 1.5) * radius * 0.52, 0),
            width: radius * 0.4,
            height: radius * (i.isEven ? 1.5 : 2),
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(40)),
            ink,
          );
        }
      case 2:
        canvas.drawCircle(center, radius, ink);
        canvas.drawCircle(
          center + Offset(radius * 0.48, -radius * 0.18),
          radius * 0.82,
          paper,
        );
    }
  }

  @override
  bool shouldRepaint(_ArtworkPainter oldDelegate) =>
      oldDelegate.colour != colour || oldDelegate.seed != seed;
}
