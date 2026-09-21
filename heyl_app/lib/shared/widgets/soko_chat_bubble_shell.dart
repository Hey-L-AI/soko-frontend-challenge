import 'package:flutter/material.dart';

/// Corner treatment for user (right-aligned) bubbles. Per Figma 7285:23397 the
/// bottom-right is the bubble's *tail* and is squared even on a lone bubble; the
/// left corners stay fully rounded. Stacking then squares the seam corners so a
/// run of replies reads as one connected column down the right edge:
///   • single / first / middle → bottom-right squared (tail or seam-below)
///   • last (bubble above, none below) → bottom-right rounded ("straight on top")
///   • top-right squared whenever a bubble sits directly above.
/// Shared by the onboarding transcript and the main chat.
BorderRadius sokoUserBubbleRadius({
  required bool prevIsUser,
  required bool nextIsUser,
}) {
  const full = Radius.circular(10);
  const squared = Radius.zero;
  return BorderRadius.only(
    topLeft: full,
    bottomLeft: full,
    topRight: prevIsUser ? squared : full,
    // Tail (or seam with a bubble below); only the group's last/bottom bubble
    // rounds off.
    bottomRight: (!prevIsUser || nextIsUser) ? squared : full,
  );
}

/// Shared visual shell for Soko chat bubbles.
///
/// Content models stay with each feature: production chat can render rich
/// [ChatMessage] content while scripted onboarding supplies plain text or its
/// own content widgets.
class SokoChatBubbleShell extends StatelessWidget {
  const SokoChatBubbleShell({
    super.key,
    required this.isUser,
    required this.backgroundColor,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final bool isUser;
  final Color backgroundColor;
  final Widget child;

  /// Corner radii — overridable so stacked bubbles can collapse the corners on
  /// the tail side (Instagram-style grouping). Defaults to a uniform 16.
  final BorderRadius borderRadius;

  /// Inner padding around [child]. Defaults to the standalone-bubble insets.
  final EdgeInsetsGeometry padding;

  double _maxWidth(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    if (screenWidth >= 1024) return 500;
    if (screenWidth >= 768) return screenWidth * 0.75;
    return screenWidth * 0.85;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: isUser
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Container(
                constraints: BoxConstraints(maxWidth: _maxWidth(context)),
                padding: padding,
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: borderRadius,
                ),
                child: child,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
