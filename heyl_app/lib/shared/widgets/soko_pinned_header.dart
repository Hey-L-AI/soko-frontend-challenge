// PROD-4080 — the app's pinned header, as a component (D118).
//
// This started life as the Discovery feed's `FeedPinnedHeader`, hardcoded to
// one page: sliders on the left wired to a single callback, the location in the
// middle, the admin-gated memories button on the right, one constructor
// parameter. Chat, the public profile and the library are all about to want a
// header, and if this one isn't reusable each of them grows its own.
//
// The app is already carrying five header implementations — `PinnedPageChrome`,
// `AuthHeader`, chat's `_buildConversationHeader`, the profile's `_TopBar` and
// the library's `_YoursPageHeader`. This exists so the next one is a reuse
// rather than a sixth.
//
// **Where this sits next to `PinnedPageChrome`** (the other pinned header, in
// `features/discovery/widgets/`): that one is *route-resolved* — the shell
// decides from the route what chrome to draw, pages cannot mount it, and it
// renders a 32 px SeasonMix list title. This one is *page-mounted* — a page
// picks its own slots — and renders the 40 px `Mobile/B1 Reg` bar from Figma
// `7304-24495`. If you are adding chrome to a page, you want this one.
//
// ## Adopting it
//
// ```dart
// final header = SokoPinnedHeaderBlock(
//   child: SokoPinnedHeader(
//     leading: SokoHeaderSlot.back(),
//     centre: SokoHeaderSlot.title(Lt.of(context).profileTitle),
//     // trailing omitted — `none` is a real value, not a TODO.
//   ),
// );
//
// SokoPinnedHeaderHost.scrollAway(
//   controller: _scrollController,
//   // The one mode that must be told the height, and it is not a constant —
//   // it carries the notch. Never write a literal; ask the block.
//   headerHeight: header.heightFor(context),
//   header: header,
//   child: myScrollable,
// )
//
// // ...or `.fixed(header: ..., child: ...)`, which takes nothing else —
// // it is always visible and never moves, so there is nothing to observe.
// // One constructor per placement, each taking only what its mode reads.
// ```
//
// ⚠️ **The `SokoPinnedHeaderBlock` is not optional decoration.** This bar is
// 40 px; what a user reads as "the header" is the block around it — paper,
// safe-area inset, and 15 above and below. An earlier version of this snippet
// passed a bare `SokoPinnedHeader` as `header:`, and the first page to follow
// it landed 30 px short of the feed (PROD-4081 → PROD-4101).
//
// See [SokoHeaderPlacement] for the three placement modes.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../l10n/generated/l10n.dart';
import 'circle_icon_button.dart';
import 'soko_brain_icon.dart';
import 'soko_back_button.dart';
import 'soko_location_line.dart';

/// Height of the bar. Figma `7304-24495`.
///
/// Doubles as the width reserved for an empty side slot, which is what keeps
/// the centre optically centred when a page uses only one button.
const double kSokoPinnedHeaderHeight = 40;

/// The pinned header: three independently-settable slots on a paper bar.
///
/// [leading] and [trailing] are nullable, and **null is a first-class value,
/// not a TODO** — an absent side still reserves [kSokoPinnedHeaderHeight] so
/// the centre does not drift toward it. The two sides always reserve the SAME
/// width, so the centre stays put whatever a page puts either side of it: one
/// button, two, a back arrow, or nothing. Pages that have not decided on their
/// buttons yet should leave the slot empty rather than borrow someone else's;
/// an empty slot is cheap to fill later, a plausible-looking wrong button has
/// to be noticed before it can be removed.
///
/// Use [SokoHeaderSlot] for the standard slot contents rather than building
/// buttons by hand — that is the whole point of the type existing.
class SokoPinnedHeader extends StatelessWidget {
  /// Left slot (right, under RTL). Null renders nothing but still reserves its
  /// width — see [_SlotLayout] for why both sides reserve the same amount.
  final Widget? leading;

  /// Centre slot. [SokoHeaderSlot.location] is the default across the app;
  /// [SokoHeaderSlot.title] is for pages that name themselves instead.
  final Widget centre;

  /// Right slot (left, under RTL). Null renders nothing but still reserves its
  /// width — see [_SlotLayout].
  final Widget? trailing;

  /// Bar fill. Defaults to [AppColors.sokoPaper].
  final Color background;

  const SokoPinnedHeader({
    super.key,
    this.leading,
    required this.centre,
    this.trailing,
    this.background = AppColors.sokoPaper,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: kSokoPinnedHeaderHeight,
      color: background,
      child: CustomMultiChildLayout(
        delegate: _SlotLayout(Directionality.of(context)),
        children: [
          if (leading != null) LayoutId(id: _Slot.leading, child: leading!),
          LayoutId(id: _Slot.centre, child: centre),
          if (trailing != null) LayoutId(id: _Slot.trailing, child: trailing!),
        ],
      ),
    );
  }
}

enum _Slot { leading, centre, trailing }

/// Lays the bar out so the centre is at the **bar's** centre, never merely
/// centred in whatever the sides left over.
///
/// A `Row` with `Expanded(Center(...))` between the two slots is the obvious
/// shape and it is subtly wrong: it centres the middle inside the *remaining*
/// space, so the moment the two sides differ in width the centre slides by half
/// the difference. Measured on the `Row` version: 40 px of imbalance moved the
/// title 20 px off-centre, silently. Every ready-made [SokoHeaderSlot] happens
/// to be 40 wide, so nothing in the app tripped it — but the first page owner
/// to put two buttons on one side would have, and a 20 px drift is the kind of
/// thing that ships.
///
/// So both sides reserve `max(leading, trailing, kSokoPinnedHeaderHeight)`.
/// The floor keeps the bar's rhythm identical whether or not a slot is filled,
/// which is what makes an empty slot a real value rather than a hole; the max
/// makes the centre's position independent of what the sides hold. The centre
/// is then constrained to what is left, so it ellipsises instead of running
/// under a button.
class _SlotLayout extends MultiChildLayoutDelegate {
  _SlotLayout(this.textDirection);

  /// Which edge [_Slot.leading] sits against. `Row` handled this for free; a
  /// custom layout has to ask.
  final TextDirection textDirection;

  @override
  void performLayout(Size size) {
    // **Unbounded on the main axis, which is what `Row` gave these slots.**
    // A Flex lays its non-flexible children out with `maxWidth: infinity`, so a
    // slot containing `Row(children: [...])` — no `mainAxisSize` argument, the
    // natural thing to write — shrink-wraps to its buttons.
    //
    // Handing it `BoxConstraints.loose(size)` instead lets that inner Row take
    // `MainAxisSize.max` at its word and claim the WHOLE bar; `side` then
    // becomes the bar's width and the centre is laid out at `maxWidth: 0`, i.e.
    // the title vanishes. The tests missed it because they wrote
    // `mainAxisSize: MainAxisSize.min`, which is not what an adopting page will
    // write. (codex, round 4.)
    final sideConstraints = BoxConstraints(maxHeight: size.height);

    Size? leadingSize;
    if (hasChild(_Slot.leading)) {
      leadingSize = layoutChild(_Slot.leading, sideConstraints);
    }
    Size? trailingSize;
    if (hasChild(_Slot.trailing)) {
      trailingSize = layoutChild(_Slot.trailing, sideConstraints);
    }

    final side = math.max(
      kSokoPinnedHeaderHeight,
      math.max(leadingSize?.width ?? 0, trailingSize?.width ?? 0),
    );

    final ltr = textDirection == TextDirection.ltr;
    double startX(Size child) => ltr ? 0 : size.width - child.width;
    double endX(Size child) => ltr ? size.width - child.width : 0;

    if (leadingSize != null) {
      positionChild(
        _Slot.leading,
        Offset(startX(leadingSize), (size.height - leadingSize.height) / 2),
      );
    }
    if (trailingSize != null) {
      positionChild(
        _Slot.trailing,
        Offset(endX(trailingSize), (size.height - trailingSize.height) / 2),
      );
    }

    final centreSize = layoutChild(
      _Slot.centre,
      BoxConstraints(
        maxWidth: math.max(0, size.width - 2 * side),
        maxHeight: size.height,
      ),
    );
    positionChild(
      _Slot.centre,
      Offset(
        (size.width - centreSize.width) / 2,
        (size.height - centreSize.height) / 2,
      ),
    );
  }

  @override
  bool shouldRelayout(_SlotLayout old) => old.textDirection != textDirection;
}

/// The standard contents for [SokoPinnedHeader]'s slots.
///
/// One namespace so autocomplete lists every variant a page can pick, and so
/// nobody hand-rolls a sixth button style. Add new variants here rather than
/// inline in a page.
abstract final class SokoHeaderSlot {
  /// Back arrow — the second standard left variant, and the one PROD-4081
  /// (Procura) consumes first.
  ///
  /// **A bare glyph, deliberately not a filled circle.** Going back is
  /// navigation, not an action on this page, so it should not read as a peer
  /// of the filled buttons beside it. It still occupies the same 40 px slot,
  /// so the row keeps one rhythm.
  ///
  /// Defaults to pop-or-fallback-to-[fallbackRoute]; pass [onTap] for a
  /// richer destination.
  static Widget back({VoidCallback? onTap, String fallbackRoute = '/'}) =>
      _BackSlot(onTap: onTap, fallbackRoute: fallbackRoute);

  /// Filter/sliders button — opens the page's filter surface.
  static Widget filters({required VoidCallback onTap}) =>
      _FiltersSlot(onTap: onTap);

  /// The user's memories. Callers own the gating: on the feed this is
  /// admin-only, because `/menu/memory` bounces everyone else.
  static Widget memories({required VoidCallback onTap}) =>
      _MemoriesSlot(onTap: onTap);

  /// Escape hatch for a page-specific action, in the same 40 px circle chrome
  /// as [filters] and [memories] so it does not look imported from elsewhere.
  static Widget icon({
    required IconData icon,
    required String semanticLabel,
    required VoidCallback onTap,
  }) => _CircleSlot(icon: icon, semanticLabel: semanticLabel, onTap: onTap);

  /// The tappable location — the default centre, and the same picker the
  /// action bar uses.
  static Widget location() => SokoLocationLine(
    iconSize: 14,
    // `Mobile/B1 Reg` off `7304:24502` — Zalando Light 18, leading-none,
    // tracking −2 %. `mobileB1Reg()` encodes all four so the token cannot
    // drift from the frame here.
    textStyle: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
  );

  /// A plain page title, for pages that name themselves instead of showing a
  /// location.
  ///
  /// Same type as [location] on purpose: the centre slot has one voice
  /// whatever it holds, so swapping a title in for a location does not change
  /// the bar's weight. Pass a localized string — this is chrome, so it belongs
  /// in the ARBs (`profileTitle` already ships in all four locales).
  static Widget title(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
  );

  /// An **editorial** page title — `Mobile/H2`, Season Mix 32.
  ///
  /// The centre slot normally has one voice ([title], [location]) so swapping
  /// a title in for a location does not change the bar's weight. This is the
  /// deliberate exception: the new library screens name themselves in the
  /// display face (Figma `7598:26026` and its four siblings, all 214 x 32 in a
  /// 400 x 40 bar). Use it only where the design specs the display face —
  /// reach for [title] everywhere else.
  ///
  /// The glyphs are taller than the 40 px bar's comfortable text height, so
  /// the bar clips nothing only because Season Mix at 32 with `height: 1.0`
  /// measures 32.
  static Widget titleLarge(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.center,
    style: AppTheme.mobileH2(color: AppColors.sokoInk),
  );
}

/// Shared chrome for the filled circle slots: 40 px, ink at 6 %, per
/// `7304-24495`.
class _CircleSlot extends StatelessWidget {
  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;

  const _CircleSlot({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => CircleIconButton(
    icon: icon,
    background: AppColors.sokoInk.withValues(alpha: 0.06),
    iconColor: AppColors.sokoInk,
    semanticLabel: semanticLabel,
    onTap: onTap,
  );
}

class _FiltersSlot extends StatelessWidget {
  final VoidCallback onTap;
  const _FiltersSlot({required this.onTap});

  @override
  Widget build(BuildContext context) => _CircleSlot(
    icon: LucideIcons.sliders_vertical,
    semanticLabel: Lt.of(context).feedPinnedHeaderFiltersLabel,
    onTap: onTap,
  );
}

class _MemoriesSlot extends StatelessWidget {
  final VoidCallback onTap;
  const _MemoriesSlot({required this.onTap});

  // `glyphBuilder`, not `icon`: the memory mark is the Figma `Icon/Brain` SVG,
  // not a Lucide glyph. Same chrome as every other slot.
  @override
  Widget build(BuildContext context) => CircleIconButton(
    glyphBuilder: (_) => const SokoBrainIcon(size: 15),
    background: AppColors.sokoInk.withValues(alpha: 0.06),
    iconColor: AppColors.sokoInk,
    semanticLabel: Lt.of(context).feedPinnedHeaderMemoriesLabel,
    onTap: onTap,
  );
}

class _BackSlot extends StatelessWidget {
  final VoidCallback? onTap;
  final String fallbackRoute;

  const _BackSlot({required this.onTap, required this.fallbackRoute});

  @override
  Widget build(BuildContext context) {
    // `SokoBackButton` carries no semantic label of its own — `Clickable` is a
    // bare MouseRegion + GestureDetector. `MergeSemantics` folds the label and
    // the gesture's tap action into ONE node; a plain `Semantics` wrapper would
    // leave a labelled node and a tappable node side by side, which a screen
    // reader announces as two things.
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: Lt.of(context).commonBack,
        child: SokoBackButton(
          // `bare` is the glyph with no surface. Its 48 px Material hit target
          // would overflow a 40 px bar, so the header asks for its own size.
          variant: SokoBackButtonVariant.bare,
          size: kSokoPinnedHeaderHeight,
          onTap: onTap,
          fallbackRoute: fallbackRoute,
        ),
      ),
    );
  }
}
