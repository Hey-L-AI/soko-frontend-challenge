// Unified search — the chat-style "View other {category}…" expander and the
// "pop" reveal used when a section expands.
//
// Replaces both onboarding's plain "+N more matches" button and the map's
// non-animated chevron expander with one control: a muted chevron row (the map
// language) plus a scale+fade "pop" on the newly revealed rows.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';

/// Arrow-led "view other {section}…" expander row. Mirrors the map's
/// `MapSuggestExpanderRow` (leading `chevron_down`, muted ink) so the two read
/// as one control, but lives in `shared/` so no surface depends on the map.
class UnifiedSearchExpanderRow extends StatelessWidget {
  const UnifiedSearchExpanderRow({
    super.key,
    required this.label,
    required this.onTap,
    this.collapse = false,
  });

  /// Localized "View other events…" (or the collapse label when [collapse]).
  final String label;
  final VoidCallback onTap;

  /// Renders the collapse variant (`chevron_up`) shown under an expanded block.
  final bool collapse;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(
              collapse ? LucideIcons.chevron_up : LucideIcons.chevron_down,
              size: 20,
              color: AppColors.sokoShade3,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  height: 1.2,
                  letterSpacing: -0.15,
                  color: AppColors.sokoShade3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Animates its [child] in with a scale + fade "pop" on mount — used to wrap the
/// rows a section reveals when its expander is tapped, so extra matches pop in
/// rather than snapping. `easeOutBack` gives the slight overshoot Zé asked for.
///
/// Honours reduce-motion: the child appears at rest with no animation.
class UnifiedSearchPopIn extends StatefulWidget {
  const UnifiedSearchPopIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 190),
  });

  final Widget child;
  final Duration duration;

  @override
  State<UnifiedSearchPopIn> createState() => _UnifiedSearchPopInState();
}

class _UnifiedSearchPopInState extends State<UnifiedSearchPopIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.85, end: 1.0).animate(_scale),
        alignment: Alignment.topCenter,
        child: widget.child,
      ),
    );
  }
}
