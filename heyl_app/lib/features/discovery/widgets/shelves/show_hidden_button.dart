import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../l10n/generated/l10n.dart';

/// Compact multi-line pill opposite the near-you shelf title. Toggles the
/// shelf between the normal filtered feed and the raw "show everything" feed.
///
/// One light-gray container holds everything:
///   - rest ([active] == false): eye + "Show hidden", a horizontal separator,
///     then the contextual count ("4 today" / "4 really close" via
///     [countLabel]).
///   - showing-all ([active] == true): just eye-off + "Show hidden", with a
///     thin outline as the "on" highlight (the fill stays light gray so the
///     pill never turns into a dark block; the raw feed hides nothing, so the
///     separator + count drop out).
///
/// A tap fires [onTap] (the notifier's `togglePersonalized`). While a toggle
/// re-fetch is in flight the button ignores taps to avoid a double round-trip.
class ShowHiddenButton extends StatelessWidget {
  const ShowHiddenButton({
    super.key,
    required this.countLabel,
    required this.active,
    required this.onTap,
    this.isLoading = false,
  });

  /// Localized contextual count, e.g. "4 today" / "4 really close". Null when
  /// the salient count is 0 (items are hidden, but none today / none really
  /// close) — the button still shows, just without the count line. Rendered
  /// on the line below the label in the rest state only.
  final String? countLabel;

  /// True when the shelf is showing the raw unfiltered feed.
  final bool active;

  /// Fired on tap — the shelf notifier's `togglePersonalized`.
  final VoidCallback onTap;

  /// Suppresses taps while a toggle re-fetch is in flight.
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final label = l10n.discoveryShowHiddenLabel;
    final showCountLine = !active && countLabel != null;

    final labelRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          active ? LucideIcons.eye_off : LucideIcons.eye,
          size: 11,
          color: AppColors.sokoInk,
        ),
        const SizedBox(width: 5),
        Text(label, style: _labelStyle),
      ],
    );

    return Semantics(
      button: true,
      label: showCountLine ? '$label, ${countLabel!}' : label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isLoading ? null : onTap,
          borderRadius: BorderRadius.circular(3),
          child: AnimatedOpacity(
            opacity: isLoading ? 0.5 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.sokoShade5,
                borderRadius: BorderRadius.circular(3),
                // "On" highlight: a thin outline, fill unchanged. Always 1px
                // (transparent when off) so toggling doesn't resize the pill.
                border: Border.all(
                  color: active ? AppColors.sokoInk : Colors.transparent,
                  width: 1,
                ),
              ),
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(child: labelRow),
                    if (showCountLine) ...[
                      const SizedBox(height: 2),
                      Container(height: 1, color: AppColors.sokoShade4),
                      const SizedBox(height: 2),
                      Text(
                        countLabel!,
                        textAlign: TextAlign.center,
                        style: _labelStyle,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const TextStyle _labelStyle = TextStyle(
    fontFamily: 'ZalandoSans',
    fontWeight: FontWeight.w200,
    fontSize: 10,
    height: 1.1,
    letterSpacing: -0.1,
    color: AppColors.sokoInk,
  );
}
