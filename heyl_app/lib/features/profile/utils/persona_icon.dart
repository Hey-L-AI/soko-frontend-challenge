import 'package:flutter/material.dart';

/// The onboarding persona illustrations (hand-drawn ink), keyed by the stable
/// persona id stored in `classification_persona_tags` and surfaced on the
/// public taste twin (`persona_tags`). Shown as a small "vibe" mark in the
/// top-right of the tastes section.
const Map<String, String> _personaAsset = {
  'curious_cosmopolitan': 'assets/images/personas/curious_cosmopolitan.png',
  'conscious_outdoors': 'assets/images/personas/conscious_outdoors.png',
  'quality_seeker': 'assets/images/personas/quality_seeker.png',
  'local_at_heart': 'assets/images/personas/local_at_heart.png',
  'golden_age': 'assets/images/personas/golden_age.png',
};

/// The full persona CARD images (Figma "Soko_Template_Story" export, the tilted
/// paper-card stack), background removed to transparent so they drop onto any
/// surface. Used for the in-app persona card (the IG-share render stays separate
/// and unchanged).
const Map<String, String> _personaCardAsset = {
  'curious_cosmopolitan':
      'assets/images/personas/cards/curious_cosmopolitan.png',
  'conscious_outdoors': 'assets/images/personas/cards/conscious_outdoors.png',
  'quality_seeker': 'assets/images/personas/cards/quality_seeker.png',
  'local_at_heart': 'assets/images/personas/cards/local_at_heart.png',
  'golden_age': 'assets/images/personas/cards/golden_age.png',
};

/// Resolve the full persona-card image for a list of tags (first known one),
/// or null if none map to a bundled card.
String? personaCardAssetForTags(List<String> tags) {
  for (final t in tags) {
    final a = _personaCardAsset[t];
    if (a != null) return a;
  }
  return null;
}

/// Resolve the illustration asset for a list of persona tags (first known one),
/// or null if none map to a bundled asset.
String? personaAssetForTags(List<String> tags) {
  for (final t in tags) {
    final asset = _personaAsset[t];
    if (asset != null) return asset;
  }
  return null;
}

/// The first persona id in [tags] that has a bundled illustration, or null.
String? personaIdForTags(List<String> tags) {
  for (final t in tags) {
    if (_personaAsset.containsKey(t)) return t;
  }
  return null;
}

/// A small persona illustration mark for the tastes-section header.
class PersonaIconMark extends StatelessWidget {
  final List<String> personaTags;
  final double size;
  const PersonaIconMark({super.key, required this.personaTags, this.size = 34});

  @override
  Widget build(BuildContext context) {
    final asset = personaAssetForTags(personaTags);
    if (asset == null) return const SizedBox.shrink();
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}
