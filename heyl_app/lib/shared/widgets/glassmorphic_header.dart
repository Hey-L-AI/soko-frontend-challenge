import 'dart:ui';
import 'package:flutter/material.dart';

/// A reusable widget that wraps content with a glassmorphic backdrop blur effect.
/// Matches the Lovable mockup's header styling with semi-transparent backgrounds
/// and blur effects.
class GlassmorphicHeader extends StatelessWidget {
  final Widget child;
  final double sigmaX;
  final double sigmaY;

  const GlassmorphicHeader({
    super.key,
    required this.child,
    this.sigmaX = 24.0, // Approximates Tailwind's backdrop-blur-xl
    this.sigmaY = 24.0,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigmaX, sigmaY: sigmaY),
        child: child,
      ),
    );
  }
}
