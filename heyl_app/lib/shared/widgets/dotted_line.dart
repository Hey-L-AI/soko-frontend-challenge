import 'package:flutter/material.dart';

/// Dotted line — matches Lovable CSS radial-gradient at 6px intervals.
/// Shared between immersive_map_hero.dart and desktop_top_nav.dart.
class DottedLine extends StatelessWidget {
  final Color color;
  final double spacing;
  final double dotSize;

  const DottedLine({
    super.key,
    required this.color,
    this.spacing = 6.0,
    this.dotSize = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = (constraints.maxWidth / spacing).floor();
        return SizedBox(
          height: dotSize * 2,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(count, (_) {
              return Container(
                width: dotSize * 2,
                height: dotSize * 2,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              );
            }),
          ),
        );
      },
    );
  }
}
