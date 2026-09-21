import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/l10n.dart';
import '../../providers/resolved_search_location_provider.dart';
import '../utils/search_location_label.dart';
import '../utils/search_location_picker.dart';
import 'bt_sq_ico.dart';

/// Soko/Pink "City, ISO2" pill shared by the idle action bar and the
/// search overlay. Renders three flavors based on the budget the host
/// hands it:
///
///   1. Full label + map-pin icon when both fit.
///   2. Drop the map-pin if dropping the icon makes the full label fit.
///   3. Drop the icon AND truncate the city portion ("Rio de Janei…, BR"),
///      preserving the ", ISO2" suffix so the country code stays
///      readable.
///
/// The host owns the budget math (knows what else is in its row); this
/// widget owns the label resolution + responsive rendering + the tap
/// behavior (opens [showLocationScopePicker] and writes back to
/// [cityScopeProvider]). Keeping the pill self-contained means every
/// host that needs a location pill — `_IdleRow` (PROD-2145),
/// `DiscoverySearchOverlay` (PROD-2221), and any future surface —
/// stays consistent without copy-pasting the label resolution + picker
/// wiring.
class ActionBarLocationPill extends ConsumerWidget {
  /// Maximum horizontal width the pill may occupy, computed by the
  /// caller from `LayoutBuilder.constraints.maxWidth` minus whatever
  /// the row's other controls need. The pill chooses one of the three
  /// flavors that fits inside this budget.
  final double availableWidth;

  /// Visual treatment. Defaults to the outlined `idle` look the action
  /// bar / search overlay use; the chat-bar bottom row passes `selected`
  /// (Soko/Pink fill) to keep the slot the Add-to-Soko pill vacated pink.
  final BtSqIcoVariant variant;

  const ActionBarLocationPill({
    super.key,
    required this.availableWidth,
    this.variant = BtSqIcoVariant.idle,
  });

  /// Returns the location label split into `(prefix, suffix)`. Only a final
  /// two-letter country code is protected as a suffix. Area labels can contain
  /// several commas ("Algés, ..., Oeiras, Portugal") and must be ellipsized as
  /// one label instead of treating everything after the first comma as fixed.
  (String prefix, String? suffix) _resolveLabelParts(WidgetRef ref, Lt l10n) {
    final label = searchLocationLabelText(
      ref.watch(resolvedSearchLocationProvider).valueOrNull,
      // A point+radius pick with no covering polygon is still a real pick —
      // name it the way the picker's own chip does, not "Location".
      unnamedArea: l10n.locationScopeUnnamedArea,
      fallback: l10n.discoveryActionBarLocationFallback,
    );
    final match = RegExp(r'^(.*)(, [A-Z]{2})$').firstMatch(label);
    if (match == null) return (label, null);
    return (match.group(1)!, match.group(2));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final (prefix, suffix) = _resolveLabelParts(ref, l10n);

    // Match BtSqIco's Text style so the painter measures exactly what
    // the chip will render.
    const labelStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w300,
      height: 1.2,
      letterSpacing: -0.14,
    );
    const hPadding = 28.0; // BtSqIco horizontal padding (14 + 14)
    const iconChrome = 22.0; // icon (14) + gap (8)

    double measure(String text) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return tp.width;
    }

    final fullLabel = suffix == null ? prefix : '$prefix$suffix';
    final fullLabelWidth = measure(fullLabel);
    final budget = availableWidth.clamp(60.0, double.infinity);
    void onTap() => openSearchLocationPicker(context, ref);
    Widget buildPill({required IconData? icon, required String label}) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: budget),
        child: BtSqIco(
          icon: icon,
          label: label,
          // Default `idle` — outlined pill (paper fill + hairline border),
          // matching the search input beside it (Figma redesign, replaces
          // the PROD-2221 gray fill). Hosts may override (see [variant]).
          variant: variant,
          onTap: onTap,
        ),
      );
    }

    // 1. Full label + icon fits → canonical pill.
    if (fullLabelWidth + iconChrome + hPadding <= budget) {
      return buildPill(icon: LucideIcons.map_pin, label: fullLabel);
    }
    // 2. Drop the icon if that makes the full label fit.
    if (fullLabelWidth + hPadding <= budget) {
      return buildPill(icon: null, label: fullLabel);
    }
    // 3. No icon AND truncate the city portion. Only the prefix is
    //    ellipsized; the suffix (", ISO2") stays put. If there's no
    //    suffix (country-only or fallback label), let BtSqIco's
    //    built-in ellipsis handle it.
    final availableForText = (budget - hPadding).clamp(0.0, budget);
    final truncated = suffix == null
        ? fullLabel
        : _truncateCityKeepingSuffix(
            city: prefix,
            suffix: suffix,
            availableForText: availableForText,
            measure: measure,
          );
    return buildPill(icon: null, label: truncated);
  }

  /// Binary-searches for the longest city prefix that fits alongside
  /// `…` + `suffix` within `availableForText`.
  String _truncateCityKeepingSuffix({
    required String city,
    required String suffix,
    required double availableForText,
    required double Function(String) measure,
  }) {
    int lo = 0;
    int hi = city.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      final candidate = '${city.substring(0, mid)}…$suffix';
      if (measure(candidate) <= availableForText) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    if (lo == 0) {
      // Even one city char + ellipsis + suffix overflows the budget.
      // Fall back to the full label and let BtSqIco's built-in
      // ellipsis chew off whatever still doesn't fit — a degenerate
      // width this small means we've already lost the layout
      // regardless.
      return '$city$suffix';
    }
    return '${city.substring(0, lo)}…$suffix';
  }
}
