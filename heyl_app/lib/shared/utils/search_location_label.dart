import '../../data/models/resolved_search_location.dart';

/// The text a surface shows for the resolved Search Center (C).
///
/// Three cases, and the middle one is the whole point of this helper:
///
/// 1. C has a place name → show it ("Arroios", "Lisboa, PT").
/// 2. C is a real pick with **no** place name — the picker's point+radius scope
///    where the backend has no covering polygon ([ResolvedSearchLocation.isUnnamedArea])
///    → show [unnamedArea], the same "Selected area" copy the picker itself
///    puts on its map chip. The user chose an area; naming it "Location" reads
///    as "we don't know where you are", which is wrong and looks broken.
/// 3. Nothing has resolved yet → [fallback], the surface's own placeholder.
///
/// Pure so it can be unit-tested without a widget tree; every label surface
/// funnels through it so cases 2 and 3 cannot drift apart per screen.
String searchLocationLabelText(
  ResolvedSearchLocation? location, {
  required String unnamedArea,
  required String fallback,
}) {
  final label = location?.label?.trim();
  if (label != null && label.isNotEmpty) return label;
  if (location?.isUnnamedArea ?? false) return unnamedArea;
  return fallback;
}
