import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Renders a cheap [placeholder] until this slot first scrolls into view, then
/// swaps in the (heavy) [child] and keeps it forever.
///
/// Built for the detail-page mini-map: a live Mapbox GL instance is the single
/// most expensive mount on the page, and it sits below the fold. Mounting it
/// eagerly puts that cost on the Hero-flight frames (and then the reveal
/// frames) even though the user cannot see it yet. Gating it on visibility
/// keeps both animations smooth and only pays for the map if the user actually
/// scrolls down to it.
///
/// [placeholder] should reserve the child's eventual size (e.g. an
/// `AspectRatio` matching the map) so the swap doesn't shift the scroll extent.
/// [visibilityKey] must be unique per slot ([VisibilityDetector] requires it).
class LazyMount extends StatefulWidget {
  const LazyMount({
    super.key,
    required this.visibilityKey,
    required this.child,
    required this.placeholder,
    this.visibleFraction = 0.01,
  });

  /// Unique key for the underlying [VisibilityDetector].
  final Key visibilityKey;

  /// The heavy widget, built once the slot becomes visible.
  final Widget child;

  /// Space-reserving stand-in shown until then.
  final Widget placeholder;

  /// Visible fraction (0–1) that triggers the mount. A hair above 0 so merely
  /// touching the viewport edge is enough.
  final double visibleFraction;

  @override
  State<LazyMount> createState() => _LazyMountState();
}

class _LazyMountState extends State<LazyMount> {
  bool _mounted = false;

  void _onVisibility(VisibilityInfo info) {
    if (_mounted) return;
    if (info.visibleFraction > widget.visibleFraction && mounted) {
      setState(() => _mounted = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_mounted) return widget.child;
    return VisibilityDetector(
      key: widget.visibilityKey,
      onVisibilityChanged: _onVisibility,
      child: widget.placeholder,
    );
  }
}
