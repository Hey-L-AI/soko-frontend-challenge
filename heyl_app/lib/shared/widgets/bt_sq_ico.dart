import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_colors.dart';

/// Variants for [BtSqIco] (mirrors Figma `4108:2975` `Bt_Sq_Ico` variants).
enum BtSqIcoVariant {
  /// Filled — Soko/Ink @ 6% bg. Used for the action-bar pills
  /// ("Cria nova zine", "Localização").
  normal,

  /// Outlined — 1 px Soko/Ink @ 6% border, transparent bg. Used for
  /// unselected category tabs.
  idle,

  /// Filled — Soko/Pink bg. Used for the active category tab.
  selected,

  /// Filled — Soko/Shade5 bg. Used for the list-page Seguir button per
  /// `docs/designs/list-page-redesign.md` § 7.1.
  shade5,

  /// Filled — Soko/Yellow bg. Used for the discovery action-bar "Cria nova
  /// zine" pill (Figma `6346:12069`).
  yellow,

  /// Filled — Soko/Lilac bg (`#E08EFB`). Used for the Discovery action-bar
  /// "Discover the city" pill (PROD-2221), which replaces the magnifier
  /// circle as the primary entry to the search overlay.
  lilac,

  /// Filled — Soko/Purple bg (`#A597FF`). Used for the chat-onboarding
  /// "Continuar" CTA (Figma `7285:23415`).
  purple,

  /// Outlined — Soko/Paper fill + Soko/Pink border by default, filling
  /// Soko/Pink only on hover/press. The design-system "pink is the interaction
  /// accent, not a default fill" treatment (mirrors the onboarding location
  /// pills). Used for onboarding profile CTAs (Editar perfil / Find contacts).
  pinkOutline,
}

/// Implementation of the Figma `Bt_Sq_Ico` design-system component
/// (`4108:2975`) — height 40, radius 6, 14 px icon + 8 px gap + label.
///
/// Three states: [BtSqIcoVariant.normal], [BtSqIcoVariant.idle],
/// [BtSqIcoVariant.selected]. Border is always 1 px transparent on the
/// fill variants so swapping between idle ↔ selected/normal doesn't shift
/// content by 2 px on each axis (see D50 in `docs/ui/design-decisions.md`).
class BtSqIco extends StatefulWidget {
  /// Leading icon. Pass `null` for label-only mode (Figma `hasIcon: false`),
  /// or use [iconAsset] for an SVG.
  final IconData? icon;

  /// Optional leading **SVG** asset path (rendered 14×14, tinted Soko/Ink).
  /// Takes precedence over [icon] when set — lets the DS button use the app's
  /// SVG icon set, not just Material glyphs.
  final String? iconAsset;

  final String label;
  final BtSqIcoVariant variant;

  /// Tap handler. Pass `null` to render the button **disabled** — dimmed, with
  /// no hover/press feedback and no tap. (Every non-null caller behaves exactly
  /// as before.)
  final VoidCallback? onTap;

  /// Overrides the [BtSqIcoVariant.selected] background — only consulted
  /// when [variant] is `selected`. Lets per-category surfaces (event /
  /// venue / zine) flow through without forking the DS primitive.
  final Color? selectedBackgroundOverride;

  /// Overrides the icon + label colour. Defaults to `Soko/Ink`, which is what
  /// every DS variant uses, so omitting it leaves existing callers pixel-
  /// identical.
  ///
  /// Exists for the same reason as [selectedBackgroundOverride], one step
  /// further: PROD-4006's feed banner takes its button fill from the **wire**,
  /// where a backoffice author can pick any hex. A fixed ink label would be
  /// unreadable on a dark fill, and the caller — which knows the fill — is the
  /// only place that can derive a legible foreground. See
  /// `core/utils/hex_color.dart`'s `foregroundOn`.
  final Color? foregroundOverride;

  /// When `true`, the inner Row stretches to fill the parent width and
  /// centers the icon+label, so the button can be wrapped in `Expanded`
  /// for sticky-footer pairs (PROD-1863). Default `false` preserves the
  /// content-sized chip shape every existing caller relies on.
  final bool expand;

  /// Fixed button height. Defaults to the DS-standard 40 px; the
  /// chat-onboarding "Continuar" CTA overrides this to match the taller
  /// Figma frame (`7285:23415`).
  final double height;

  /// When `true`, a 14×14 spinner replaces the leading icon so a pending
  /// action reads inside the button rather than as a separate row. The label
  /// still renders — swap it to a "…searching" string while pending if wanted.
  final bool loading;

  const BtSqIco({
    super.key,
    required this.icon,
    this.iconAsset,
    required this.label,
    required this.variant,
    required this.onTap,
    this.selectedBackgroundOverride,
    this.foregroundOverride,
    this.expand = false,
    this.height = 40,
    this.loading = false,
  });

  @override
  State<BtSqIco> createState() => _BtSqIcoState();
}

class _BtSqIcoState extends State<BtSqIco> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final fg = widget.foregroundOverride ?? AppColors.sokoInk;
    final inkAt6 = AppColors.sokoInk.withValues(alpha: 0.06);
    final (Color bg, Color borderColor) = switch (widget.variant) {
      BtSqIcoVariant.normal => (inkAt6, Colors.transparent),
      // Figma redesign — idle outlines use the slightly stronger
      // Soko/Shade45 hairline (was ink @ 6 %) so the pills read against
      // the paper background, matching the Descobre a cidade mock.
      BtSqIcoVariant.idle => (Colors.transparent, AppColors.sokoShade45),
      BtSqIcoVariant.selected => (
        widget.selectedBackgroundOverride ?? AppColors.sokoPink,
        Colors.transparent,
      ),
      BtSqIcoVariant.shade5 => (AppColors.sokoShade5, Colors.transparent),
      BtSqIcoVariant.yellow => (AppColors.sokoYellow, Colors.transparent),
      BtSqIcoVariant.lilac => (AppColors.sokoLilac, Colors.transparent),
      BtSqIcoVariant.purple => (AppColors.sokoPurple, Colors.transparent),
      BtSqIcoVariant.pinkOutline => (AppColors.sokoPaper, AppColors.sokoPink),
    };

    // Web/desktop hover + pressed overlay. Alphas match `SokoCtaButton`
    // (0.10 / 0.16) so the two CTA widgets feel like one family.
    Color effectiveBg = bg;
    if (widget.variant == BtSqIcoVariant.pinkOutline) {
      // Pink is the interaction accent for this variant: outline at rest, fill
      // Soko/Pink on hover/press (matches the onboarding location pills).
      if (_isPressed || _isHovered) effectiveBg = AppColors.sokoPink;
    } else if (_isPressed) {
      effectiveBg = Color.alphaBlend(
        AppColors.sokoInk.withValues(alpha: 0.16),
        bg,
      );
    } else if (_isHovered) {
      effectiveBg = Color.alphaBlend(
        AppColors.sokoInk.withValues(alpha: 0.10),
        bg,
      );
    }

    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: enabled ? (_) => setState(() => _isHovered = true) : null,
        onExit: enabled ? (_) => setState(() => _isHovered = false) : null,
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _isPressed = true) : null,
          onTapUp: enabled
              ? (_) {
                  setState(() => _isPressed = false);
                  widget.onTap!();
                }
              : null,
          onTapCancel: () => setState(() => _isPressed = false),
          child: AnimatedScale(
            scale: _isPressed ? 0.96 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: widget.height,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: effectiveBg,
                border: Border.all(color: borderColor, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: widget.expand
                    ? MainAxisSize.max
                    : MainAxisSize.min,
                mainAxisAlignment: widget.expand
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  if (widget.loading)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg,
                      ),
                    )
                  else if (widget.iconAsset != null)
                    SvgPicture.asset(
                      widget.iconAsset!,
                      width: 14,
                      height: 14,
                      colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
                    )
                  else if (widget.icon != null)
                    Icon(widget.icon, size: 14, color: fg),
                  // Icon-only mode: empty label suppresses both the 8 px gap
                  // AND the Text so the icon sits centered inside the chip's
                  // symmetric horizontal padding instead of being pushed to
                  // the left by a phantom trailing gap.
                  if (widget.label.isNotEmpty) ...[
                    if (widget.loading ||
                        widget.iconAsset != null ||
                        widget.icon != null)
                      const SizedBox(width: 8),
                    // Flexible + ellipsis so the chip degrades gracefully when a
                    // narrow parent (e.g. Flexible/Expanded on iPhone SE) hands
                    // it less room than its content wants. In unconstrained use
                    // the Row stays MainAxisSize.min, so visuals are unchanged.
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w300,
                          height: 1.2,
                          letterSpacing: 0,
                          color: fg,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
