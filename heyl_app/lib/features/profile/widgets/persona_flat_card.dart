import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../user_profiling/utils/profiling_strings.dart';
import '../utils/persona_icon.dart';

/// Front colour per persona. Same five values the photographic card
/// ([PersonaCard]) matches, but here they are the card itself — this card is
/// drawn natively rather than composited over the Figma "Soko_Template_Story"
/// export, so nothing has to line up with baked pixels and every string is
/// localized by construction.
const Map<String, Color> _personaFill = {
  'curious_cosmopolitan': Color(0xFFEDE77D),
  'conscious_outdoors': AppColors.sokoGreen,
  'quality_seeker': Color(0xFFA698FD),
  'local_at_heart': Color(0xFFF68685),
  'golden_age': Color(0xFFE08DFB),
};

/// "A tua persona" — a flat, full-width colour card carrying the persona
/// illustration, its name in caps and the localized description.
///
/// Renders nothing when the tags don't map to a known persona.
class PersonaFlatCard extends StatelessWidget {
  final List<String> personaTags;
  const PersonaFlatCard({super.key, required this.personaTags});

  @override
  Widget build(BuildContext context) {
    final id = personaIdForTags(personaTags);
    final asset = personaAssetForTags(personaTags);
    if (id == null || asset == null) return const SizedBox.shrink();
    final fill = _personaFill[id] ?? AppColors.sokoGreen;

    return Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      child: Column(
        children: [
          Image.asset(
            asset,
            height: 96,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(height: 14),
          Text(
            profilingPersonaName(context, id).toUpperCase(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'SeasonMix',
              fontWeight: FontWeight.w600,
              fontSize: 21,
              height: 1.05,
              letterSpacing: -0.2,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            profilingPersonaDescription(context, id),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontWeight: FontWeight.w300,
              fontSize: 14,
              height: 1.35,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
        ],
      ),
    );
  }
}
