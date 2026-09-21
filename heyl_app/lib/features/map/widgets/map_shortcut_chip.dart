import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// PROD-2996 — the Map page's **colorful** quick-filter shortcut chip (Figma
/// `7102-20592`/`7102-20593` "Tag"): a solid [color] fill, [AppColors.sokoInk]
/// label (Zalando Light 14), radius 6, height 30, **no border and no leading
/// icon** — the icon is an intended divergence from the Figma.
///
/// Two rows use it, and the shared styling is the point — they must read as
/// the same family:
///
/// - `MapShortcutChips` — the quick-filter row (each chip a mapped palette
///   colour) and the "Reset all filters" / "Search this area" pills (white).
/// - `MapDomainTagRow` (PROD-3652) — the focused-search domain tags, white
///   when unselected and [AppColors.sokoPink] when selected.
///
/// **Selection is expressed through [color], deliberately — there is no
/// `selected` flag.** A boolean would have to pick the two colours itself,
/// which is how a shared component starts accumulating one caller's policy;
/// leaving it to the caller keeps this widget purely presentational and made
/// the domain-tag row free to build.
///
/// Distinct from the filter-panel option chip (`_SmallChip` in
/// `map_filter_bar.dart`), which keeps its own h24/r2 paper/pink styling.
class MapShortcutChip extends StatelessWidget {
  const MapShortcutChip({
    super.key,
    required this.label,
    required this.color,
    this.onTap,
    this.icon,
    this.semanticsSelected,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  /// PROD-2993 — an optional leading glyph. Only "Search this area" uses one:
  /// it is a *map* action wearing a *filter* row's clothes, and the magnifying
  /// glass is what tells the two apart at a glance.
  final IconData? icon;

  /// PROD-3652 — announces on/off state to assistive tech for chips that have
  /// one (the domain tags). Null for the one-shot shortcut chips, where
  /// "selected" is meaningless and announcing it would be a lie: colour alone
  /// carries the state visually, and colour is not available to a screen
  /// reader.
  final bool? semanticsSelected;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
    );
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        height: 1.2,
        letterSpacing: -0.14,
        color: AppColors.sokoInk,
      ),
    );
    final content = SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Center(
          widthFactor: 1,
          child: icon == null
              ? text
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: AppColors.sokoInk),
                    const SizedBox(width: 6),
                    Flexible(child: text),
                  ],
                ),
        ),
      ),
    );
    final Widget chip = Material(
      color: color,
      shape: shape,
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, customBorder: shape, child: content),
    );

    // The colourful shortcut chips are high-contrast against the map on their
    // own, but the **white** variant (the "Limpar filtros" reset pill — and any
    // future white pill in this row, e.g. a "search this area" CTA) washes out
    // over the Mapbox canvas. Lift only the white ones with the same soft ink
    // shadow the on-map floating back button uses (soko_back_button.dart), so
    // they read as the same family of floating white controls. Coloured chips
    // stay flat.
    final Widget lifted = color != Colors.white
        ? chip
        : DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.sokoInk.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: chip,
          );

    final selected = semanticsSelected;
    if (selected == null) return lifted;
    return Semantics(selected: selected, button: true, child: lifted);
  }
}
