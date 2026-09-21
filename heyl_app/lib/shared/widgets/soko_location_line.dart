// PROD-4005 / PROD-4080 — the tappable location line, shared by every header
// that shows one. Lives in `shared/` rather than the feed because it is the
// default centre slot of [SokoPinnedHeader] and any page adopting that header
// gets it for free.
//
// D31, D32 and D40 all say "tapping the location opens the location picker",
// and all three mean the SAME picker the action bar already uses. One widget,
// so the three headers cannot drift apart on *behaviour*.
//
// **They deliberately drift on type, which is why the style is a required
// argument rather than a default.** The three are not one component at three
// sizes:
//
//   * top header (`7304:23423`) — icon 22, `Mobile/H3`;
//   * pinned header (`7304:24500`) — icon 14, `Mobile/B1 Reg`;
//   * alt pinned header — no Figma frame at all (D40 describes it in words),
//     and its label sits beside a 14 px "in" and a 14 px filter button.
//
// The parameters used to default to `14 / 14`, which silently made every call
// site the pinned header's numbers — and those were the wrong ones. Requiring
// both means a new header has to state its type instead of inheriting someone
// else's by accident.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../l10n/generated/l10n.dart';
import '../../providers/resolved_search_location_provider.dart';
import '../utils/search_location_label.dart';
import '../utils/search_location_picker.dart';

/// The resolved location label, the picker's "Selected area" copy when C is a
/// named-less point+radius pick, or a fallback when nothing has resolved yet.
String sokoLocationLabel(WidgetRef ref, Lt l10n) => searchLocationLabelText(
  ref.watch(resolvedSearchLocationProvider).valueOrNull,
  unnamedArea: l10n.locationScopeUnnamedArea,
  fallback: l10n.feedHeaderLocationFallback,
);

/// Gap between the pin and the label.
///
/// **A constant 6, not a fraction of the icon.** Both frames set `gap-[6px]`
/// regardless of icon size (`7304:23423` at icon 22, `7304:24500` at icon 14).
/// This was `iconSize * 0.43` under a comment reading "Figma: 20 px gap at
/// icon 14" — but the 20 is the label's *x offset* inside the group, which is
/// the 14 px icon plus the 6 px gap. Same misread that put 20 between
/// `FeedMetaLine`'s icon and its text.
const double _kIconLabelGap = 6;

class SokoLocationLine extends ConsumerWidget {
  /// Figma: 22 on the top header (`7304:23424`), 14 on both pinned ones
  /// (`7304:24501`).
  final double iconSize;

  /// The label's type. No default — see the note at the top of this file.
  final TextStyle textStyle;

  const SokoLocationLine({
    super.key,
    required this.iconSize,
    required this.textStyle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final label = sokoLocationLabel(ref, l10n);

    void openPicker() => openSearchLocationPicker(context, ref);

    return Semantics(
      button: true,
      label: label,
      // `excludeSemantics` replaces the descendants' nodes rather than merging
      // with them — without it the inner `Text` contributes its own node and a
      // screen reader announces the location twice. It also drops the
      // GestureDetector's tap action, so the node has to declare `onTap`
      // itself; the two share one handler so they cannot diverge.
      excludeSemantics: true,
      onTap: openPicker,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: openPicker,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.map_pin,
                size: iconSize,
                color: AppColors.sokoInk,
              ),
              const SizedBox(width: _kIconLabelGap),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
