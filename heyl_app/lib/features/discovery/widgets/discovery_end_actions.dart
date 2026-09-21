import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/session_provider.dart';
import '../../notifications/widgets/notifications_top_button.dart';
import 'create_menu_sheet.dart';

/// End-of-scroll CTAs rendered directly below [DiscoveryFooter]'s
/// "That's all folks" caption (PROD-1980). Two full-width pills:
///
///   - Soko/Pink "Adiciona à Soko" — toggles [CreateMenuSheet], same
///     unified create-flow entry as the chat-bar `AddToSokoPill`. Same
///     icon (link), same label key (`discoveryChatBarAddToSoko`), same
///     fill — the two surfaces are intentionally in lockstep so the CTA
///     reads as one consistent action regardless of where the user taps.
///   - Soko/Ink "Fala com a Soko" — starts a NEW chat (clears
///     `activeSessionIdProvider` first, then `context.go('/chat')`)
///     so the user lands on the empty WelcomeView instead of resuming
///     their last conversation. Same pattern as the sidebar's
///     `_onNewChat` (chat_sidebar_drawer.dart). Matches the chat-bar's
///     active send button (`AppColors.sokoInk` background +
///     `AppColors.sokoPaper` glyph) so "talking to Soko" reuses the
///     same visual signal as "send a message to Soko".
///
/// Spacing convention: 30 px above (from the footer caption), the two
/// 40 px pills side-by-side with a 6 px gap (each Expanded to share the
/// width evenly), then the screen's existing 96 px `bottomNavReserve`
/// handles the bottom of the viewport. The footer itself is mounted with
/// `hasTrailingGap: false` so its 104 px reserve doesn't push the pills
/// away from the caption.
class DiscoveryEndActions extends ConsumerWidget {
  const DiscoveryEndActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 30),
      child: Row(
        // No CrossAxisAlignment.stretch: this Row sits in an unbounded-height
        // Column (_DiscoveryShelves), so stretching the cross axis would hand
        // children infinite height. Each _Pill is already a fixed 40 px tall.
        children: [
          // Reminders moved into the notifications inbox (its "Reminders"
          // tab), so the bell no longer needs its own chrome slot here.
          const NotificationsTopButton(),
          const SizedBox(width: 6),
          Expanded(
            child: _Pill(
              icon: LucideIcons.link,
              label: l10n.discoveryChatBarAddToSoko,
              background: AppColors.sokoPink,
              onTap: () => CreateMenuSheet.toggle(
                context,
                ref,
                entryPoint: EntryPoint.homeBottom,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _Pill(
              icon: LucideIcons.message_circle,
              label: l10n.discoveryEndActionsTalkToSoko,
              background: AppColors.sokoInk,
              foreground: AppColors.sokoPaper,
              onTap: () {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackChatOpen(entryPoint: EntryPoint.homeBottom);
                ref
                    .read(activeSessionIdProvider.notifier)
                    .setActiveSession(null);
                context.go(AppRoutes.chat);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width pill mirroring the chrome of `DiscoveryHelpUsActions._Pill`
/// and `AddToSokoPill` (height 40, padding 14×10, radius 6, 8 px icon→label
/// gap, animated press scale) but taking a Lucide [IconData] instead of an
/// SVG asset so we don't need to ship dedicated artwork for these CTAs.
/// [foreground] defaults to [AppColors.sokoInk] for light pills; pass
/// [AppColors.sokoPaper] when sitting on a dark fill (e.g. sokoInk).
class _Pill extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  const _Pill({
    required this.icon,
    required this.label,
    required this.background,
    required this.onTap,
    this.foreground = AppColors.sokoInk,
  });

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: _isPressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: widget.background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 14, color: widget.foreground),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w300,
                      height: 1.2,
                      letterSpacing: -0.14,
                      color: widget.foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
