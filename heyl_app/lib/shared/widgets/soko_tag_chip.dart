// PROD-4081 — the "Tag" chip and the horizontally-scrolling bar it lives in
// (Figma `7598-24582`). The Discovery feed, Library, "Descobre a cidade" and
// Procura share the complete Tag design system: buttons, joined groups, row
// geometry and named motion treatments.
//
// **What this replaces, and why the layout is inverted.** The feed's filter row
// used to be five `Expanded` columns — equal fifths, each label
// `maxLines: 1, overflow: ellipsis`. Under pressure the *content* gave way, so
// on a narrow phone "Pessoas" clipped. The rule is now the other way round:
// chips size to their content and the **row** gives way, by scrolling. That is
// the pattern the Map page's shortcut row already uses.
//
// **This and `MapShortcutChip` are the same Figma component with two skins**,
// and the metrics below are deliberately identical to it — height 30, radius 6,
// 10 px horizontal padding, a 14 px icon 6 px from the label, Zalando Light 14.
// They differ only in surface: the map paints a solid palette colour with no
// border and drops the Tag's icon; this one is paper with a hairline border and
// keeps the icon. Consolidating the two is possible and is deliberately NOT
// done here — it would mean changing the map's selection model, which expresses
// state through `color` and has no `selected` flag at all.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/page_layout.dart';
import 'measure_size.dart';

part 'soko_tag_bar.dart';

/// Figma `7598-24582`: every chip, and the row, is 30 tall.
const double kSokoTagChipHeight = 30;

/// Gap between chips. Figma's tag x-offsets are 6 apart throughout.
const double kSokoTagChipGap = 6;

/// Default page margin the row starts and ends on.
///
/// PROD-4101 promoted this number out of the feed into `core/theme`, so it is
/// aliased rather than copied — one definition, and `shared/` no longer has to
/// spell a feature's constant to avoid depending on it.
const double kSokoTagBarMargin = kSokoPageMargin;

/// Corner radius. Measured off the frame's rendered corner, and the same 6 the
/// map's chip uses — the two must not drift, they are one component.
const double kSokoTagChipRadius = 6;

/// Icon size and its gap to the label (Figma: icon at x10, text at x30).
const double kSokoTagChipIconSize = 14;
const double kSokoTagChipIconLabelGap = 6;

/// Horizontal padding inside a labelled chip (Figma: 10 either side).
const double kSokoTagChipHPadding = 10;

/// Label type for every Tag chip: Zalando Light 14, tracking −0.14.
///
/// Height is 1.2, not the token's leading-none: at 1.0 a 14 px Zalando line
/// box clips descenders on Android. [MapShortcutChip] and the Library pills
/// share this style so the three cannot drift by a pixel of baseline.
TextStyle sokoTagChipLabelStyle({required Color color}) {
  return TextStyle(
    fontFamily: 'ZalandoSans',
    fontSize: 14,
    fontWeight: FontWeight.w300,
    height: 1.2,
    letterSpacing: -0.14,
    color: color,
  );
}

/// Opacity applied to a disabled chip's ink. Carried over from the feed's
/// previous filter row, where "disabled but visible" is the established
/// treatment for a filter that exists in the design and not yet in the backend.
const double _kDisabledOpacity = 0.35;

/// Controlled selection colours supported by the Tag design system.
///
/// Features choose a semantic palette tone, not an arbitrary [Color], so a
/// palette or contrast adjustment remains centralized here.
enum SokoTagTone {
  pink(AppColors.sokoPink),
  blue(AppColors.sokoBlue),
  green(AppColors.sokoGreen),
  purple(AppColors.sokoPurple),
  yellow(AppColors.sokoYellow);

  const SokoTagTone(this.color);

  final Color color;
}

/// Named motion treatments supported by [SokoTagBar].
///
/// These pick along two axes that are deliberately named together, because a
/// feature should choose a *treatment*, not assemble one:
///
/// * **The row engine.** [standard] keeps a lazy `ListView`. [reveal] and
///   [reorder] measure every item and position it, which is what produces the
///   **reveal on mount** — every slot starts at zero width and eases out to
///   its measured one, so the row unfolds from its leading edge.
/// * **The chip chrome timing** — the selection fill and the joined corners.
///
/// [standard] is the stable, lazily built search bar: no reveal, snappy chips.
/// [reveal] is [standard]'s chrome on a measured row, for a bar that should
/// unfold when it appears without slowing its selection down — the feed.
/// [reorder] adds items being inserted, removed or promoted while the bar stays
/// visible, and slows the chip chrome to match that travel — Library.
enum SokoTagBarMotion {
  standard,
  reveal,
  reorder;

  /// Whether the row measures and positions each slot itself. Measured rows
  /// animate in on mount; the lazy row simply appears.
  bool get isMeasured => this != SokoTagBarMotion.standard;

  /// Row travel: the mount reveal, and any insertion, removal or promotion.
  Duration get duration => switch (this) {
    SokoTagBarMotion.standard => kThemeChangeDuration,
    SokoTagBarMotion.reveal ||
    SokoTagBarMotion.reorder => const Duration(milliseconds: 600),
  };

  Curve get curve => switch (this) {
    SokoTagBarMotion.standard => Curves.fastOutSlowIn,
    SokoTagBarMotion.reveal || SokoTagBarMotion.reorder => Curves.easeOutCubic,
  };

  /// Chip chrome: the selection fill and the joined corners. Kept separate from
  /// [duration] so a bar can borrow the row's reveal without also inheriting
  /// the slower selection that suits a reordering bar.
  Duration get chipDuration => switch (this) {
    SokoTagBarMotion.standard ||
    SokoTagBarMotion.reveal => kThemeChangeDuration,
    SokoTagBarMotion.reorder => const Duration(milliseconds: 600),
  };

  Curve get chipCurve => switch (this) {
    SokoTagBarMotion.standard ||
    SokoTagBarMotion.reveal => Curves.fastOutSlowIn,
    SokoTagBarMotion.reorder => Curves.easeOutCubic,
  };

  bool get animatesSelection => this == SokoTagBarMotion.reorder;
}

/// One filter chip: icon + label, or a label alone.
///
/// Selection is a **fill swap to [AppColors.sokoPink]**, per Zé's ruling
/// (2026-08-31) — the Figma frame ships only the unselected variant, and the
/// pink is the selection language the Discovery pills already used, so nothing
/// is lost in the move.
class SokoTagChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;

  /// Controlled fill used while [selected]. Pink is the primary selection;
  /// joined level-two filters can use one of the palette accents.
  final SokoTagTone tone;

  /// `false` renders the chip dimmed and inert — the design without a dead end.
  /// A disabled chip keeps its border so the row's rhythm does not change.
  final bool enabled;

  final VoidCallback? onTap;

  /// Whether this Tag owns its accessibility node. Set to false only when a
  /// composite parent owns both the tap and its semantics (for example an
  /// anchored dropdown trigger).
  final bool provideSemantics;

  /// Announced instead of silence when [enabled] is false — the feed passes
  /// "Em breve" so a screen-reader user is told the filter exists but is not
  /// built yet, rather than meeting a button that does nothing.
  final String? disabledHint;

  const SokoTagChip({
    super.key,
    required this.label,
    this.icon,
    this.selected = false,
    this.tone = SokoTagTone.pink,
    this.enabled = true,
    this.onTap,
    this.provideSemantics = true,
    this.disabledHint,
  });

  @override
  Widget build(BuildContext context) {
    final style = _SokoTagItemStyleScope.maybeOf(context);
    final ink = enabled
        ? AppColors.sokoInk
        : AppColors.sokoInk.withValues(alpha: _kDisabledOpacity);

    return _TagSurface(
      selected: selected,
      selectedFill: tone.color,
      joinLeft: style?.joinLeft ?? false,
      joinRight: style?.joinRight ?? false,
      enabled: enabled,
      onTap: onTap,
      motion: style?.motion ?? SokoTagBarMotion.standard,
      provideSemantics: provideSemantics,
      semanticsLabel: label,
      hint: enabled ? null : disabledHint,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kSokoTagChipHPadding),
        child: Row(
          // **`min`, and this is the whole point of the redesign.** A `max` (or
          // an `Expanded` wrapper) would put the chip back on a fixed share of
          // the row and reintroduce the truncation this replaced.
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: kSokoTagChipIconSize, color: ink),
              const SizedBox(width: kSokoTagChipIconLabelGap),
            ],
            Text(
              label,
              // **No `maxLines`/`overflow` on purpose.** The chip is sized by
              // its text, so there is nothing to overflow — adding an ellipsis
              // here would be dead code that quietly re-enables truncation the
              // day someone constrains the chip.
              style: sokoTagChipLabelStyle(color: ink),
            ),
          ],
        ),
      ),
    );
  }
}

/// The icon-only chip: a 30×30 circle with a 14 px glyph (Figma `7598-24583`).
///
/// The feed uses one for `Procura`; Library uses the same component for search
/// and clear. **Circular, not radius-6**: it reads as a different kind of
/// control from the labelled filters beside it because it performs an action
/// rather than selecting a content category.
class SokoTagIconChip extends StatelessWidget {
  final IconData icon;

  /// Announced to assistive tech, which cannot see the glyph.
  final String semanticsLabel;

  final bool enabled;
  final VoidCallback? onTap;

  const SokoTagIconChip({
    super.key,
    required this.icon,
    required this.semanticsLabel,
    this.enabled = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _TagSurface(
      selected: false,
      selectedFill: AppColors.sokoPink,
      enabled: enabled,
      onTap: onTap,
      motion:
          _SokoTagItemStyleScope.maybeOf(context)?.motion ??
          SokoTagBarMotion.standard,
      semanticsLabel: semanticsLabel,
      circular: true,
      child: SizedBox(
        width: kSokoTagChipHeight,
        child: Icon(
          icon,
          size: kSokoTagChipIconSize,
          color: enabled
              ? AppColors.sokoInk
              : AppColors.sokoInk.withValues(alpha: _kDisabledOpacity),
        ),
      ),
    );
  }
}

/// Shared chrome for both chips: the fill, the hairline and the tap target.
class _TagSurface extends StatelessWidget {
  final Widget child;
  final bool selected;
  final Color selectedFill;
  final bool enabled;
  final bool circular;
  final bool joinLeft;
  final bool joinRight;
  final VoidCallback? onTap;
  final SokoTagBarMotion motion;
  final bool provideSemantics;
  final String semanticsLabel;
  final String? hint;

  const _TagSurface({
    required this.child,
    required this.selected,
    required this.selectedFill,
    required this.enabled,
    required this.onTap,
    required this.semanticsLabel,
    this.circular = false,
    this.joinLeft = false,
    this.joinRight = false,
    this.motion = SokoTagBarMotion.standard,
    this.provideSemantics = true,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final radius = circular
        ? BorderRadius.circular(kSokoTagChipHeight / 2)
        : BorderRadius.only(
            topLeft: joinLeft ? Radius.zero : const Radius.circular(kSokoTagChipRadius),
            bottomLeft: joinLeft
                ? Radius.zero
                : const Radius.circular(kSokoTagChipRadius),
            topRight: joinRight ? Radius.zero : const Radius.circular(kSokoTagChipRadius),
            bottomRight: joinRight
                ? Radius.zero
                : const Radius.circular(kSokoTagChipRadius),
          );
    final shape = RoundedRectangleBorder(
      borderRadius: radius,
      // The selected chip carries no hairline — the pink is the edge. Sampled
      // off the Figma frame: the selected variant's border row is the same
      // pink as its interior.
      side: selected
          ? BorderSide.none
          : const BorderSide(color: AppColors.sokoShade45, width: 1),
    );

    final tappable = enabled && onTap != null;

    final targetFill = selected ? selectedFill : AppColors.sokoPaper;

    // The bar honours this in three places; the chip has to agree, or a
    // reduce-motion user gets a row that snaps into its new order while the
    // fill and the joined corners keep easing for another 600 ms. `Material`
    // lerps its own colour AND its shape over `animationDuration`, so zeroing
    // that is what stops the corner squaring off gradually.
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion ? Duration.zero : motion.chipDuration;

    Widget buildSurface(Color fill) => SizedBox(
      height: kSokoTagChipHeight,
      child: Material(
        color: fill,
        shape: shape,
        animationDuration: duration,
        child: tappable
            ? InkWell(
                onTap: onTap,
                customBorder: shape,
                child: Center(widthFactor: 1, child: child),
              )
            : Center(widthFactor: 1, child: child),
      ),
    );

    final surface = motion.animatesSelection && !reduceMotion
        ? TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: targetFill),
            duration: duration,
            curve: motion.chipCurve,
            builder: (_, fill, __) => buildSurface(fill ?? targetFill),
          )
        : buildSurface(targetFill);

    if (!provideSemantics) return ExcludeSemantics(child: surface);

    return Semantics(
      button: true,
      enabled: tappable,
      selected: selected,
      label: semanticsLabel,
      hint: hint,
      excludeSemantics: true,
      onTap: tappable ? onTap : null,
      child: surface,
    );
  }
}
