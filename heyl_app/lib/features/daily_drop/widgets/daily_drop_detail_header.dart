import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/month_abbr.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/soko_card_image.dart' show SokoEntityKind;
import '../../../shared/widgets/soko_dotted_rule.dart';
import '../utils/daily_drop_palette.dart';
import 'daily_drop_wordmark.dart';

/// Branded DAILY DROP header (PROD-3439).
///
/// PROD-3439 put this on the **venue / event** detail page, gated on the route
/// carrying `?from=daily-drop&dropId=…` (the PROD-2785 attribution params).
/// PROD-3950/3951 moved it to the Daily Drop's own page, which mounts it
/// unconditionally — it *is* the drop surface, so there is nothing to gate on
/// and no query params to read. PROD-3952 removes the venue/event host.
///
/// Layout, top → bottom (Figma `7204:22712` event / `7204:22891` venue):
/// the DAILY DROP wordmark, a dotted rule, a date row (`Mar. 19` …
/// `2026`), a second dotted rule — then the page's normal media/content
/// continues below. The **background is not painted here**: the event and
/// venue pages already paint `sokoEvent` / `sokoVenue`, which is exactly
/// what the six design frames show, so the header is purely additive.
///
/// The back arrow above it is the shell's `PinnedPageChrome`, not ours.
///
/// Width is inherited: the host body sits inside `PageContent`, which caps
/// the column at `PageLayout.desktopContentMaxWidth` on desktop, so the
/// wordmark scales with the column rather than the window.
class DailyDropDetailHeader extends ConsumerWidget {
  /// Which entity page this is — selects the wordmark palette (each
  /// excludes its own page background colour).
  final SokoEntityKind kind;

  /// The drop's own instant — the `/daily` payload's `generated_at`, passed
  /// straight from the `DailyDrop` the page already holds. (It used to be
  /// threaded through the route as `?dropDate=`; PROD-3951 removed that
  /// transport along with the venue/event branches.)
  ///
  /// Drives **both** the seed and the displayed date, but differently, and
  /// the difference is deliberate:
  ///   - seed  → UTC day, so it matches the backend's UTC-keyed drop row;
  ///   - shown → local, so it matches the Discovery card's own date label.
  ///
  /// Null when the drop carries no `generated_at`: the header still renders,
  /// falling back to the default colour and hiding the date row rather than
  /// inventing a date.
  final DateTime? dropDate;

  const DailyDropDetailHeader({
    super.key,
    required this.kind,
    required this.dropDate,
  });

  /// Figma vertical rhythm: 30 px above the wordmark (below the pinned
  /// chrome), and 30 px between each subsequent block.
  static const double _gap = 30;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? userId = ref.watch(currentUserIdProvider);
    final DateTime? date = dropDate;

    // Guests have no stable id to key on (and the backend omits
    // `palette_seed` for them) — `dailyDropWordmarkColor` falls back to the
    // default variant when the seed is null.
    final String? seed = (userId != null && date != null)
        ? dailyDropPaletteSeed(userId: userId, target: date)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: _gap),
        DailyDropWordmark(
          bandColor: dailyDropWordmarkColor(seed: seed, kind: kind),
          // Shared-element partner of the Discovery ready card's wordmark: the
          // title flies up into this header when the drop detail opens.
          heroTag: dailyDropWordmarkHeroTag,
        ),
        if (date != null) ...<Widget>[
          const SizedBox(height: _gap),
          _DateRow(date: date),
        ],
        const SizedBox(height: _gap),
      ],
    );
  }
}

/// Dotted rule · `Mar. 19` — `2026` · dotted rule.
class _DateRow extends StatelessWidget {
  final DateTime date;

  const _DateRow({required this.date});

  @override
  Widget build(BuildContext context) {
    // Local, to agree with the Discovery card's own `_resolveDate` label —
    // the *seed* is the UTC day, which is a separate concern. See
    // `docs/features/daily-drop-and-newsletter.md` §1.7.
    final DateTime local = date.toLocal();
    final String locale = Localizations.localeOf(context).toString();

    // Same composition the card's editorial overlay uses, so the two read
    // identically: locale-aware month abbreviation + explicit period.
    // `formatMonthAbbr` capitalises, which is what the designs show in every
    // locale.
    final String shortDate = '${formatMonthAbbr(local, locale)}. ${local.day}';
    final String year = DateFormat('y', locale).format(local);

    final TextStyle style = AppTheme.body(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: AppColors.sokoInk,
      height: 1.2,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SokoDottedRule(color: AppColors.sokoInk, dotRadius: 1, gap: 5),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(shortDate, style: style),
            Text(year, style: style),
          ],
        ),
        const SizedBox(height: 8),
        const SokoDottedRule(color: AppColors.sokoInk, dotRadius: 1, gap: 5),
      ],
    );
  }
}
