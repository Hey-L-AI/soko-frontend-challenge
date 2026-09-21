import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:heyl_app/core/theme/app_colors.dart';
import 'package:heyl_app/features/lists/providers/cover_share_render_provider.dart';
import 'package:heyl_app/features/share/providers/share_controller.dart';
import 'package:heyl_app/features/share/widgets/soko_share_sheet.dart';
import 'package:heyl_app/l10n/generated/l10n.dart';

/// Direct-to-Instagram-Story shortcut button rendered next to the
/// plain share button on shareable surfaces (event, venue, list
/// header, zine viewer, weekly-bundle overlay). Tapping fires the
/// controller and opens Instagram as soon as the BE-rendered PNG is
/// ready — no intermediate picker or preview sheet.
///
/// Callers own the tap handler so surfaces with custom pre-share logic
/// (owner-on-private-list warning, per-card state read, etc.) can
/// intercept before invoking [shareDirectlyToInstagramStory] with
/// the resolved entity params.
///
/// The button self-watches the share controller for its
/// `(shareContext, entityId)` key and swaps the IG glyph for a
/// spinner while the controller is in `ShareLoading` /
/// `ShareHandingOff` — the BE-rendered PNG can take 1–3 s and without
/// this feedback the button used to look inert between tap and
/// Instagram taking focus.
///
/// Visual: 40×40 circular button filled with the IG brand gradient
/// ([instagramGradient]) and a white Instagram glyph. Sized to sit
/// flush next to sibling 40 px action buttons on each surface.
///
/// Pass [fillColor] to override the gradient with a solid brand colour
/// (e.g. `AppColors.sokoLilac` on event / venue detail so the IG shortcut
/// reads louder than the faint sibling Save / Reminder chips). Solid
/// fills carry a `sokoInk` glyph — the design-system pairing for
/// coloured fills (see `SokoCtaButton`'s `lilac` variant) — since white on
/// these light brand surfaces fails contrast (~2.6:1 vs ~6.0:1 for ink).
class IgDirectShareButton extends ConsumerWidget {
  const IgDirectShareButton({
    super.key,
    required this.onTap,
    required this.shareContext,
    required this.entityId,
    this.size = 40,
    this.iconSize,
    this.filled = true,
    this.fillColor,
  });

  final VoidCallback onTap;

  /// The share-context slug (`event` / `venue` / `list` / `list-item` /
  /// `daily-drop` / etc.) used to key the share controller state so the
  /// button's busy indicator reflects THIS surface's share, not a
  /// sibling one.
  final String shareContext;

  /// The entity id paired with [shareContext] to form the controller
  /// key.
  final String entityId;

  final double size;

  /// Glyph size. Defaults to 20 px in the filled ("brand pill") variant
  /// and 14 px in the unfilled variant so it lines up with the sibling
  /// Save / Share / Reminder chips on event / venue / list-header
  /// surfaces (all 14 px Lucide glyphs).
  final double? iconSize;

  /// When `true` (default) the button renders as a solid IG-gradient
  /// circle with a white glyph — the loud "brand pill" look used inside
  /// the share sheet's channel row. When `false`, the button matches the
  /// sibling Save / Share / Reminder chips on event / venue / list-header
  /// surfaces: 40 px Soko/Ink @ 6 % circle with a Soko/Ink glyph.
  final bool filled;

  /// When non-null (and [filled] is `true`), the circle is filled with
  /// this solid colour instead of the IG brand gradient, and the glyph
  /// switches to `sokoInk` (the DS pairing for coloured fills). Used to
  /// make the IG shortcut a high-visibility chip on event / venue detail
  /// via `AppColors.sokoLilac`. Ignored when [filled] is `false`.
  final Color? fillColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // IG-Story handoff is native-only (iOS `UIPasteboard` +
    // `instagram-stories://`, Android `FileProvider` + `ADD_TO_STORY`
    // intent). `InstagramStoryHandoff._isSupportedPlatform` already
    // returns false on web so the tap would produce `ShareIgNotInstalled`,
    // but the button itself shouldn't sit on-screen advertising a
    // capability the web build can't deliver. Matches the sibling
    // `kIsWeb` gates on the WhatsApp / Stories tiles inside
    // `soko_share_sheet.dart`. Bails BEFORE `ref.watch` to skip the
    // controller subscription entirely on web.
    if (kIsWeb) return const SizedBox.shrink();

    final label = Lt.of(context).shareIgDirectSemanticsLabel;
    // Solid custom-colour fill (e.g. sokoRed): pair with a sokoInk glyph
    // per the design system; white on sokoRed fails contrast.
    final solidFill = filled && fillColor != null;
    final glyphColor = filled
        ? (solidFill ? AppColors.sokoInk : Colors.white)
        : AppColors.sokoInk;
    final effectiveIconSize = iconSize ?? (filled ? 20 : 14);

    final key = (shareContext: shareContext, entityId: entityId);
    final state = ref.watch(shareControllerProvider(key));
    // PROD-3217 — for list shares, also treat a pending/in-flight cover
    // render as busy so tapping right after a cover edit (while the debounced
    // re-render is still producing the fresh PNG) is disabled with a spinner
    // instead of firing a share against a not-yet-updated cover. Keyed by the
    // list UUID, matching the render service (change-cover sheet + share path).
    final coverBusy = shareContext == 'list'
        ? ref.watch(coverRenderInProgressProvider(entityId))
        : false;
    // Any in-flight state on the key counts as busy — the direct button
    // only fires `instagramStoryDirect`, and the generic sheet (which
    // shares this key on the same surface) is modal so it can't be
    // open while the direct button is visible.
    final busy = state is ShareLoading || state is ShareHandingOff || coverBusy;

    return Semantics(
      label: label,
      button: true,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: busy ? null : onTap,
          child: MouseRegion(
            cursor: busy
                ? SystemMouseCursors.progress
                : SystemMouseCursors.click,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: (filled && !solidFill) ? instagramGradient : null,
                color: filled
                    ? fillColor
                    : AppColors.sokoInk.withValues(alpha: 0.06),
              ),
              child: Center(
                child: busy
                    ? SizedBox(
                        width: effectiveIconSize,
                        height: effectiveIconSize,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(glyphColor),
                        ),
                      )
                    : Icon(
                        LucideIcons.instagram,
                        size: effectiveIconSize,
                        color: glyphColor,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
