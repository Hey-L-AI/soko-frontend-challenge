import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../user_profiling/utils/profiling_strings.dart';
import '../utils/persona_icon.dart';

/// Front card colour per persona — the colour Flutter actually DRAWS for the
/// card background, measured off a render, not read from Figma. The overlays
/// below paint onto the card PNG, so a mismatch shows as a visible rectangle on
/// a large flat field, and two things pull the drawn colour away from the Figma
/// value:
///
///  1. the exports are 256-colour quantized, which shifted every colour 1-2
///     units (golden_age is #E08EFC in Figma but #E08DFB in the PNG palette);
///  2. the palette entries are NOT opaque — alpha 253-254, an artefact of the
///     re-export in #1070 — so the decoded, premultiplied pixel lands a further
///     +1 above the palette value on quality_seeker and curious_cosmopolitan.
///
/// The backgrounds are otherwise perfectly flat (a text-free patch is a single
/// colour, 100%), so matching the drawn value makes the overlay seamless.
/// Re-measure from a render if the cards are ever re-exported.
const Map<String, Color> _personaFront = {
  'curious_cosmopolitan': Color(0xFFEDE77D),
  'conscious_outdoors': Color(0xFFB0EE8B),
  'quality_seeker': Color(0xFFA698FD),
  'local_at_heart': Color(0xFFF68685),
  'golden_age': Color(0xFFE08DFB),
};

/// Tilted cards behind the front one (for the native mini-card).
const Map<String, List<Color>> _personaStack = {
  'curious_cosmopolitan': [Color(0xFFF78786), Color(0xFFE08EFC)],
  'conscious_outdoors': [Color(0xFFF78786), Color(0xFFE08EFC)],
  'quality_seeker': [Color(0xFFB1EF8C), Color(0xFFF78786)],
  'local_at_heart': [Color(0xFFE08EFC), Color(0xFFB1EF8C)],
  'golden_age': [Color(0xFFEEE77D), Color(0xFFB1EF8C)],
};

// The card PNGs are the Figma "Soko_Template_Story" export, re-exported clean at
// 880x994 (RGBA, 256-colour, edge-bled) — same framing as the retired 560x633
// crop, so the baked-description fractions below still line up.
const double _cardAspect = 880 / 994;

// The baked description block, as fractions of the card image, so we can paint
// over it (with the front colour) and drop the localized description on top.
// Kept strictly BETWEEN the two dashed rules (below the name, above the card
// foot) so those rules stay visible.
const double _descLeft = 0.145;
const double _descWidth = 0.71;
// Start just above the baked dashed rule (~0.739) so we cover it and redraw a
// clean one on top of the overlay; end above the card-foot rule.
const double _descTop = 0.732;
const double _descHeight = 0.158;

// PROD-3263 — the baked HEADER block (kicker + rule + persona name), same
// treatment as the description above. Both baked strings are frozen in whatever
// language the Figma export happened to be in: the name in English ("GOLDEN
// AGE"), the kicker in Portuguese ("A tua personalidade"). So a PT user saw an
// EN name and an EN user saw a PT kicker; covering the band fixes both.
//
// Measured on all five 880x994 card PNGs — the bands are pixel-identical across
// personas, and every glyph falls inside 0.178..0.820 w, so the description
// overlay's left/width cover them with margin:
//   kicker      0.5141..0.5392 h
//   dashed rule 0.5644..0.5664 h
//   name line 1 0.5956..0.6539 h
//   name line 2 0.6680..0.7264 h
// Top sits below the illustration (ends ~0.48) and above the kicker; the bottom
// meets _descTop so the two overlays are contiguous.
const double _headTop = 0.500;
const double _headHeight = _descTop - _headTop;
// Mid-lines of each baked band — what the overlay text is centred on. Using the
// mid-line rather than the band edges keeps position independent of type size
// (the bands measure ink, which is shorter than the font's line box).
const double _kickerMid = (0.5141 + 0.5392) / 2;
const double _headRuleMid = (0.5644 + 0.5664) / 2;
const double _nameMid = (0.5956 + 0.7264) / 2;
// The box AutoSizeText fits the name into. Deliberately ~7% taller than the
// baked ink band: a font's line box is taller than its ink, so a box sized to
// the ink draws glyphs smaller than the baked ones. 1.07 is the compromise —
// SeasonMix is ~4.6% wider-per-height than the baked face, so width and height
// cannot both match exactly; this splits it (width 1.02x, height 0.98x).
const double _nameBandHeight = (0.7264 - 0.5956) * 1.07;
// Type sizes, as fractions of the card width. Tuned by rendering the card at its
// native 880x994 and measuring the drawn ink against the baked ink for the SAME
// string — kicker against the baked Portuguese one, name in English against the
// baked English one. (Comparing across languages measures the copy, not the type.)
// Both land within ~2% of the baked extent.
const double _kickerFontScale = 0.0394;
const double _nameFontScale = 0.0985;

/// The user's Soko persona card.
///
/// The full/enlarged card is the real Figma image (pixel-exact stack of cards)
/// with every baked text block — kicker, persona name, description — painted
/// over and replaced by the LOCALIZED copy (the image's own text is frozen in
/// whichever language it was exported in). [mini] is a small native chip (Soko +
/// illustration + name) for inline use; it is drawn from scratch rather than
/// from the image, so it needs no overlay.
///
/// Renders nothing when the tags don't map to a known persona.
class PersonaCard extends StatelessWidget {
  final List<String> personaTags;
  final double maxWidth;
  final bool center;
  final bool mini;
  final double miniWidth;

  const PersonaCard({
    super.key,
    required this.personaTags,
    this.maxWidth = 230,
    this.center = true,
    this.mini = false,
    this.miniWidth = 104,
  });

  @override
  Widget build(BuildContext context) {
    final card = personaCardAssetForTags(personaTags);
    final id = personaIdForTags(personaTags);
    if (card == null || id == null) return const SizedBox.shrink();

    if (mini) return _mini(context, card, id);

    final body = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showCardViewer(context, card, id),
        child: _localizedCard(context, card, id),
      ),
    );
    return center ? Center(child: body) : body;
  }

  /// The Figma card image with the baked header (kicker + name) and description
  /// painted over + the localized copy on top.
  Widget _localizedCard(BuildContext context, String asset, String id) {
    // Collapse newlines/paragraph breaks so every persona/locale reads as one
    // flowing paragraph — keeps the block a consistent shape + size.
    final desc = profilingPersonaDescription(
      context,
      id,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    final front = _personaFront[id] ?? AppColors.sokoPink;
    return AspectRatio(
      aspectRatio: _cardAspect,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final h = c.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(asset, fit: BoxFit.fill),
              _header(context, id, front, w, h),
              Positioned(
                left: _descLeft * w,
                top: _descTop * h,
                width: _descWidth * w,
                height: _descHeight * h,
                child: Container(
                  color: front,
                  child: ClipRect(
                    child: Column(
                      children: [
                        // Redraw the dashed rule that sits above the description
                        // (the original one is covered by this overlay).
                        SizedBox(height: 0.008 * h),
                        _dashedRule(width: _descWidth * w),
                        Expanded(
                          child: Center(
                            child: Text(
                              desc,
                              textAlign: TextAlign.center,
                              // Fixed size (no per-card auto-shrink) so the
                              // description reads the same on every card.
                              style: TextStyle(
                                fontFamily: 'ZalandoSans',
                                fontSize: 0.026 * w,
                                height: 1.24,
                                color: AppColors.sokoInk,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// PROD-3263 — paints over the baked kicker + persona name and redraws them
  /// localized, mirroring the description overlay below it.
  ///
  /// The name is set one word per line (as on the reveal screen) with
  /// [AutoSizeText] shrinking to fit: the baked art wraps to exactly two lines,
  /// but the real names run 2-3 words and vary by locale — "Golden Age" /
  /// "Era Dourada" against "Local at Heart" / "Só Coisas Boas" / "Ar Livre
  /// Consciente". A fixed size would overflow the band on the three-word ones.
  Widget _header(
    BuildContext context,
    String id,
    Color front,
    double w,
    double h,
  ) {
    // The ARB copy is lower-case ("a tua personalidade"); the baked art renders
    // it capitalized, so match that and keep the card looking as it shipped.
    final kicker = Lt.of(context).personaCardKicker;
    final name = profilingPersonaName(context, id).toUpperCase();
    // One word per line — AutoSizeText then shrinks the font so the widest word
    // fits its line, never breaking mid-word. Transversal across personas and
    // locales, no per-persona tuning (same approach as persona_reveal_screen).
    final words = name
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);

    return Positioned(
      left: _descLeft * w,
      top: _headTop * h,
      width: _descWidth * w,
      height: _headHeight * h,
      child: Container(
        color: front,
        child: ClipRect(
          // Positioned rather than a Column: the bands above are measured on the
          // INK of the baked text (ascender to descender), which is shorter than
          // a font's line box. Sizing a cell to the ink band and fitting the text
          // into it shrinks the glyphs well below the baked ones — so position
          // and type size are kept independent here, each band centred on its
          // measured mid-line.
          child: Stack(
            children: [
              _band(
                centerY: (_kickerMid - _headTop) * h,
                height: 0.06 * h,
                width: _descWidth * w,
                child: Text(
                  kicker.isEmpty
                      ? kicker
                      : kicker[0].toUpperCase() + kicker.substring(1),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'SeasonMix',
                    fontSize: _kickerFontScale * w,
                    height: 1,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
              // Redraw the rule between the kicker and the name (the baked one
              // is under this overlay), same as the description block does.
              Positioned(
                top: (_headRuleMid - _headTop) * h,
                left: 0,
                child: _dashedRule(width: _descWidth * w),
              ),
              _band(
                centerY: (_nameMid - _headTop) * h,
                height: _nameBandHeight * h,
                // Inset so the longest word ("COSMOPOLITAN") can never reach the
                // overlay edge — the baked names stop at 0.820 w, this band runs
                // to 0.855 w. AutoSizeText shrinks to the narrower box instead.
                width: _descWidth * w - 2 * (0.03 * w),
                child: AutoSizeText(
                  words.join('\n'),
                  textAlign: TextAlign.center,
                  maxLines: words.length,
                  wrapWords: false,
                  stepGranularity: 1,
                  minFontSize: 8,
                  style: TextStyle(
                    fontFamily: 'SeasonMix',
                    fontSize: _nameFontScale * w,
                    height: 0.88,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One overlay text band, centred on [centerY] (measured from the top of the
  /// header overlay). [height] is deliberately generous — it exists to centre
  /// the child, not to constrain it, so the type size stays independent of the
  /// measured ink band.
  Widget _band({
    required double centerY,
    required double height,
    required double width,
    required Widget child,
  }) {
    return Positioned(
      top: centerY - height / 2,
      left: 0,
      right: 0,
      height: height,
      child: Center(
        child: SizedBox(
          width: width,
          child: Center(child: child),
        ),
      ),
    );
  }

  void _showCardViewer(BuildContext context, String asset, String id) {
    showDialog<void>(
      context: context,
      barrierColor: AppColors.sokoInk.withValues(alpha: 0.55),
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        final maxW = (size.width * 0.9).clamp(240.0, 480.0);
        final maxH = size.height * 0.85;
        return GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: maxW,
                      maxHeight: maxH,
                    ),
                    child: _localizedCard(ctx, asset, id),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(
                      LucideIcons.x,
                      color: Colors.white,
                      size: 26,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- Dashed rule (matches the card's separators) ---

  Widget _dashedRule({required double width}) {
    final dash = (0.014 * width).clamp(3.0, 9.0);
    final gap = dash * 0.75;
    final n = (width / (dash + gap)).floor().clamp(1, 200);
    return SizedBox(
      width: width,
      height: 1.4,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(
          n,
          (_) => Container(width: dash, height: 1.4, color: AppColors.sokoInk),
        ),
      ),
    );
  }

  // --- Compact native mini-card (Soko + illustration + name) ---

  Widget _mini(BuildContext context, String cardAsset, String id) {
    final illustration = personaAssetForTags(personaTags);
    final name = profilingPersonaName(context, id);
    final front = _personaFront[id] ?? AppColors.sokoPink;
    final stack =
        _personaStack[id] ?? const [AppColors.sokoLilac, AppColors.sokoRed];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showCardViewer(context, cardAsset, id),
      child: SizedBox(
        width: miniWidth,
        child: AspectRatio(
          aspectRatio: 0.82,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: Transform.translate(
                  offset: const Offset(-6, -4),
                  child: Transform.rotate(
                    angle: -0.09,
                    child: _miniBack(stack.length > 1 ? stack[1] : front),
                  ),
                ),
              ),
              Positioned.fill(
                child: Transform.translate(
                  offset: const Offset(6, -2),
                  child: Transform.rotate(
                    angle: 0.07,
                    child: _miniBack(stack.isNotEmpty ? stack[0] : front),
                  ),
                ),
              ),
              _miniFront(front, illustration, name),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniBack(Color color) => Container(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: AppColors.sokoInk8),
    ),
  );

  Widget _miniFront(Color color, String? illustration, String name) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 5, 6, 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppColors.sokoInk8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Soko',
            style: TextStyle(
              fontFamily: 'SeasonMix',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 3),
          if (illustration != null)
            Expanded(child: Image.asset(illustration, fit: BoxFit.contain)),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              name.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'SeasonMix',
                fontSize: 10,
                height: 1.05,
                letterSpacing: -0.1,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
