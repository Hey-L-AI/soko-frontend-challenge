/// Deterministic Daily Drop colour variant (PROD-3439).
///
/// Six Figma frames exist for the branded daily-drop surfaces (file
/// `d4BCnyUHe2705J7ecQtaIH`, nodes `7204:22712` / `22891` / `23070` /
/// `23249` / `23428` / `23607`). Across all six, **only the DAILY DROP
/// wordmark fill changes** — the page background and the entity tag chips
/// are identical and already match what the app paints today. So the
/// variant is a single colour, and every value is an existing
/// [AppColors] token: no new tokens, no new assets, no page recoloured.
///
/// See `docs/features/daily-drop-and-newsletter.md` §1.7 for the full
/// rule, the rationale, and the alternatives that were rejected.
library;

import 'package:flutter/painting.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/soko_texture.dart';
import '../../../shared/widgets/soko_card_image.dart' show SokoEntityKind;

/// Wordmark palette for an event drop — the event page background is
/// [AppColors.sokoEvent], so green is deliberately absent.
///
/// Order is the Figma frame order and is **load-bearing**: it is what
/// `index` selects into. Reordering silently reassigns every user's
/// colour, so treat this list as append-only unless that is the intent.
const List<Color> _eventWordmarkPalette = <Color>[
  AppColors.sokoBlue, // 7204:22712
  AppColors.sokoPurple, // 7204:23070
  AppColors.sokoRed, // 7204:23428
];

/// Wordmark palette for a venue drop — the venue page background is
/// [AppColors.sokoVenue], so blue is deliberately absent. Same
/// append-only caveat as [_eventWordmarkPalette].
const List<Color> _venueWordmarkPalette = <Color>[
  AppColors.sokoGreen, // 7204:22891
  AppColors.sokoPink, // 7204:23249
  AppColors.sokoYellow, // 7204:23607
];

/// The wordmark colour at [index] for [kind], wrapping out of range.
///
/// Bypasses the seed — for the debug swatch picker and for tests that need a
/// specific variant. Production surfaces should call
/// [dailyDropWordmarkColor] so every surface agrees.
Color dailyDropWordmarkColorAt({
  required int index,
  required SokoEntityKind kind,
}) {
  // Event is the DEFAULT, venue the special case — not symmetric on purpose.
  // A drop that is still generating has no entity yet, so the surface asking
  // for a colour cannot know its kind; falling back to the event palette
  // keeps that state branded instead of blank, and matches what most drops
  // turn out to be.
  final List<Color> palette = kind == SokoEntityKind.venue
      ? _venueWordmarkPalette
      : _eventWordmarkPalette;
  return palette[index % palette.length];
}

/// The seed string every Daily Drop surface hashes to pick its colour.
///
/// `'<userId>:<targetDayUTC>'`, where [target] is an instant belonging to
/// the drop the surface is **referring to** — not "now":
///
///   - open state      → the drop's own instant (`generated_at`)
///   - countdown state → the next window's `opens_at`
///
/// so the colour changes when the *target drop* changes rather than at
/// midnight. That is the intended behaviour, not a side effect.
///
/// [target] is normalised with `.toUtc()`. This is not cosmetic: the
/// backend keys a drop row to the **UTC** calendar day
/// (`get_todays_daily_recommendation` → `recommended_at >=` UTC midnight),
/// and the agreed contract for the visibility window is that *"the target
/// drop of a window is the row for the UTC calendar day of `opens_at`"*.
/// Hashing a local date would drift from that for any user away from UTC
/// and let two surfaces disagree about the same drop. Never pass a
/// `.toLocal()` instant, and never substitute `DateTime.now()`.
///
/// Note this is deliberately *not* the same as the date the header
/// **displays**, which is local so it matches the Discovery card. Display
/// is local; the seed is UTC.
///
/// Byte-identical to the `visibility.palette_seed` the backend will return
/// once PROD-3436 ships. This function is then a best-effort mirror of the
/// server seed for old clients, not the authority — prefer the server
/// field when it is present.
String dailyDropPaletteSeed({
  required String userId,
  required DateTime target,
}) {
  final DateTime utc = target.toUtc();
  final String y = utc.year.toString().padLeft(4, '0');
  final String m = utc.month.toString().padLeft(2, '0');
  final String d = utc.day.toString().padLeft(2, '0');
  return '$userId:$y-$m-$d';
}

/// The DAILY DROP wordmark colour for [kind], selected from [seed].
///
/// Uses [stableHash] (SHA-1) rather than [Object.hashCode]: Dart does not
/// guarantee `String.hashCode` is stable across platforms, so the VM and
/// dart2js would disagree and web would paint a different colour from
/// native for the same drop. Mirrors `sokoTextureForSeed`, which picks a
/// texture from a seed the same way.
///
/// A null or empty [seed] falls back to the first palette entry — the
/// variant the ticket originally shipped as the default, and the case for
/// guests (the backend omits `palette_seed` for them, since there is no
/// stable user id to key on).
///
/// Colours may repeat on consecutive days; with three entries that happens
/// about a third of the time. That is accepted for now (Zé, 2026-08-07) —
/// simplicity over an anti-repeat rule that would need yesterday's seed
/// threaded in too.
Color dailyDropWordmarkColor({
  required String? seed,
  required SokoEntityKind kind,
}) {
  if (seed == null || seed.isEmpty) {
    return dailyDropWordmarkColorAt(index: 0, kind: kind);
  }
  return dailyDropWordmarkColorAt(index: stableHash(seed), kind: kind);
}
