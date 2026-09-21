import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/cached_image.dart';
import '../utils/profile_style.dart';
import 'textured_avatar.dart';

/// One avatar slot for [MutualAvatarsRow.people]: a photo when [url] is set,
/// else a seeded initial placeholder (the same tint + letter treatment as
/// [TexturedAvatar], drawn as a circle) so a person with no profile photo still
/// gets a face in the cluster instead of being silently dropped.
@immutable
class MutualAvatar {
  /// Profile photo URL. Empty/null → the seeded initial placeholder is drawn.
  final String? url;

  /// Drives the placeholder's initial letter. No name → a plain tinted circle,
  /// never a "?" (same rule as [TexturedAvatar]).
  final String? name;

  /// Stable per-person tint seed (pass the user id). Falls back to [name].
  final String? seed;

  const MutualAvatar({this.url, this.name, this.seed});
}

/// A cluster of overlapping mini round profile photos (the mutual followers you
/// share with someone) followed by a "{N} in common" label — shown on the
/// Locals surfaces, Instagram-style. The mini round avatar matches the one next
/// to a zine's curator username.
///
/// Shows up to 3 photos: 2 mutual → 2 photos, 3 → 3 photos, 4+ → 3 photos with
/// a small "+" badge poking out the bottom-left of the third, signalling there
/// are more.
class MutualAvatarsRow extends StatelessWidget {
  /// Legacy photo-only slots: each is a URL, and a person with no photo is
  /// **dropped** (empty URLs are filtered out, no placeholder). Kept for the
  /// surfaces that only ever have photos; new callers that want a placeholder
  /// for photoless people should pass [people] instead.
  final List<String> avatars;

  /// Richer per-person slots (takes precedence over [avatars] when non-null).
  /// Unlike [avatars] a photoless person is **not** dropped — it draws a seeded
  /// initial placeholder — so the avatar count stays honest with the "{name}
  /// vai" / "liked by" copy beside it.
  final List<MutualAvatar>? people;

  /// The full mutual-followers count (drives the "+" overflow badge).
  final int totalCount;
  final String text;
  final TextStyle textStyle;

  /// Diameter of each mini avatar.
  final double size;

  /// How much each avatar tucks under the previous one. Defaults to 6; the
  /// zine follow-line passes 4 to match Figma's `mr-[-4]` cluster.
  final double overlap;

  /// Optional glyph pinned to the far left, before the avatar cluster, saying
  /// what KIND of social proof this line is — a bookmark for "saved/followed
  /// by", a thumb for "liked by". Without it the two lines look identical
  /// until you read them.
  final Widget? leading;

  /// Glyph shown when a (non-empty) avatar URL fails to load. Defaults to a
  /// person glyph — every caller shows *people* avatars — instead of
  /// `CachedImage`'s generic image-placeholder mountain (PROD-3160).
  final IconData errorIcon;

  const MutualAvatarsRow({
    super.key,
    this.avatars = const [],
    this.people,
    required this.totalCount,
    required this.text,
    required this.textStyle,
    this.size = 16,
    this.overlap = 6,
    this.errorIcon = Icons.person,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    // [people] wins when set (photoless slots draw a placeholder); otherwise
    // fall back to the legacy photo-only [avatars] (empties dropped).
    final shown = people != null
        ? people!.take(3).toList()
        : avatars
              .where((u) => u.isNotEmpty)
              .take(3)
              .map((u) => MutualAvatar(url: u))
              .toList();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 6)],
        if (shown.isNotEmpty) ...[
          MutualAvatarCluster(
            people: shown,
            size: size,
            overlap: overlap,
            hasMore: totalCount > shown.length,
            // A little extra room below so the "+" badge can poke out
            // below-left of the last photo without being clipped. Reserved
            // unconditionally — this row's height must not change with the
            // overflow count.
            height: size + 5,
            errorIcon: errorIcon,
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
      ],
    );
  }
}

/// The overlapping cluster of mini round profile photos, on its own.
///
/// Extracted from [MutualAvatarsRow] (PROD-4443) so the people-feed person card
/// can put the same faces inside a **wrapping** `Text.rich` — a leading
/// `WidgetSpan` whose text flows onto further lines — rather than the
/// single-line `Row` that row is. Same drawing, same photoless placeholder,
/// same "+" overflow badge; only the thing it sits in differs.
///
/// [people] is drawn **as given** — cap it before passing (both callers cap at
/// 3). [height] is the caller's too: the ringed circles paint
/// `size + 2 * `[ringWidth] tall from the top, and a caller that also shows the
/// "+" badge needs room under them, so there is no single right answer to bake
/// in here.
class MutualAvatarCluster extends StatelessWidget {
  /// The faces to draw, in order, already capped by the caller.
  final List<MutualAvatar> people;

  /// Diameter of each mini avatar, before the ring.
  final double size;

  /// How much each avatar tucks under the previous one.
  final double overlap;

  /// Draw the "+" badge below-left of the last photo (there are more people
  /// than the ones shown).
  final bool hasMore;

  /// Height of the box the cluster paints into — see the class doc.
  final double height;

  /// Glyph shown when a (non-empty) avatar URL fails to load.
  final IconData errorIcon;

  /// The paper ring around each photo, which is what separates two overlapping
  /// faces. Painted as a border, so it grows each circle by `2 * ringWidth`.
  static const double ringWidth = 1.5;

  const MutualAvatarCluster({
    super.key,
    required this.people,
    required this.size,
    required this.height,
    this.overlap = 6,
    this.hasMore = false,
    this.errorIcon = Icons.person,
  });

  /// Horizontal space [people] occupies at this [size] / [overlap] — the first
  /// face in full, each subsequent one stepped by `size - overlap`.
  static double widthFor(int count, double size, double overlap) =>
      count <= 0 ? 0 : size + (count - 1) * (size - overlap);

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    final step = size - overlap;

    return SizedBox(
      width: widthFor(people.length, size, overlap),
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = 0; i < people.length; i++)
            Positioned(
              left: i * step,
              top: 0,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.sokoPaper,
                    width: ringWidth,
                  ),
                ),
                child: ClipOval(child: _avatar(people[i])),
              ),
            ),
          if (hasMore)
            Positioned(
              // Bottom-left of the last photo, mostly outside it.
              left: (people.length - 1) * step - 3,
              top: size - 8,
              child: _PlusBadge(diameter: size * 0.85),
            ),
        ],
      ),
    );
  }

  /// One slot: the profile photo when [MutualAvatar.url] is set, else a seeded
  /// initial placeholder — the same per-person tint and letter [TexturedAvatar]
  /// draws, shaped as a circle to match the cluster.
  Widget _avatar(MutualAvatar a) {
    final url = a.url?.trim() ?? '';
    if (url.isNotEmpty) {
      return CachedImage(
        imageUrl: url,
        width: size,
        height: size,
        errorIcon: errorIcon,
      );
    }
    final name = a.name?.trim() ?? '';
    final initial = name.isNotEmpty
        ? name.characters.first.toUpperCase()
        : null;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: TexturedAvatar.seededPlaceholderColor(a.seed ?? a.name),
      child: initial == null
          ? null
          : Text(
              initial,
              style: Pt.name.copyWith(fontSize: size * 0.5, height: 1),
            ),
    );
  }
}

/// The two social-proof glyphs used as [MutualAvatarsRow.leading]. Same assets
/// as the markers on the profile's own Saved list, so a bookmark means the same
/// thing wherever it appears.
class SocialProofGlyph {
  SocialProofGlyph._();

  static Widget saved({double size = 14}) => _glyph('bookmark-fill', size);

  static Widget liked({double size = 14}) => _glyph('thumb-up-fill', size);

  static Widget _glyph(String asset, double size) =>
      SvgPicture.asset('assets/images/icons/detail/$asset.svg', height: size);
}

/// The small "+" overflow badge (more mutual followers than shown).
class _PlusBadge extends StatelessWidget {
  final double diameter;
  const _PlusBadge({required this.diameter});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: AppColors.sokoInk,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.sokoPaper, width: 1.2),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.add, size: diameter * 0.7, color: AppColors.sokoPaper),
    );
  }
}
