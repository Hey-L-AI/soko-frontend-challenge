// Shared parsing for **server-supplied** colours.
//
// The app already consumes backend hex in one place — share-channel assets
// carry `background_top_color` / `background_bottom_color` — and PROD-4006 adds
// a second, the feed banner's ground and button fills. Two private copies of
// the same six lines is how they drift, so this is the one place that decides
// what a colour string means.
//
// The defensive posture is the point. These strings come off the wire, are
// authored by a human in a backoffice, and are not validated by the schema
// beyond "it is a string". Anything unparseable returns null so the caller can
// fall back to a design-system colour, rather than throwing on a value nobody
// will see until it reaches a user.

import 'dart:ui';

/// Parses a server-supplied colour string, or returns null if it is not one.
///
/// Accepts `#RRGGBB`, `RRGGBB`, `#AARRGGBB` and `AARRGGBB`, case-insensitive,
/// with surrounding whitespace tolerated. Six-digit forms are opaque.
///
/// Returns null — never throws, and never guesses — for everything else:
/// an empty string, a CSS name (`rebeccapurple`), an `rgb()` function, a
/// three-digit shorthand (`#fff`), or any string with a non-hex character.
/// **Three-digit shorthand is deliberately rejected rather than expanded**: it
/// is not a form any Soko surface authors, and silently accepting a
/// half-understood syntax is how a value that *looks* handled renders wrong.
Color? parseHexColor(String? hex) {
  if (hex == null) return null;

  var value = hex.trim();
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length == 6) value = 'FF$value';
  if (value.length != 8) return null;

  // `int.tryParse` with radix 16 accepts a leading sign, so `+FFFFFF` and
  // `-0000FF` would parse into nonsense. Reject anything that is not purely
  // hex digits before parsing.
  if (!RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(value)) return null;

  final argb = int.tryParse(value, radix: 16);
  return argb == null ? null : Color(argb);
}

/// A foreground colour that stays legible on [background].
///
/// Used where the background is **server-supplied** and the foreground is not,
/// so the two cannot be chosen together. A backoffice author picking a dark
/// banner ground should not be able to produce unreadable copy, and asking them
/// to pick a matching text colour just moves the failure one field along.
///
/// The 0.5 threshold is `Color.computeLuminance`'s own relative luminance,
/// which is already the WCAG definition — light grounds get ink, dark grounds
/// get paper.
Color foregroundOn(
  Color background, {
  required Color onLight,
  required Color onDark,
}) => background.computeLuminance() > 0.5 ? onLight : onDark;
