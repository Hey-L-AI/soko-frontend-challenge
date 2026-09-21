import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

/// Shared Soko texture primitives.
///
/// These were originally defined in
/// `features/lists/utils/zine_cover_recipe.dart` (the zine-cover recipe
/// system). They were lifted here so non-list surfaces — e.g. the
/// venue/event card fallback floor ([SokoCardImage]) — can reuse the same
/// deterministic texture selection without `shared/` importing `features/`.
///
/// `zine_cover_recipe.dart` re-exports these names, so every existing zine
/// call site keeps compiling unchanged.

/// Deterministic 32-bit hash of a string. Uses SHA-1 so the value is
/// stable across web/iOS/Android (Dart's [String.hashCode] is NOT
/// stable across platforms). Returns a positive int in [0, 2^32).
int stableHash(String s) {
  final Digest d = sha1.convert(utf8.encode(s));
  // Read the first 4 bytes as a big-endian unsigned int.
  final ByteData bd = ByteData.sublistView(Uint8List.fromList(d.bytes));
  return bd.getUint32(0, Endian.big);
}

/// The light paper grain — Figma's "Gstaik Textures", the single texture the
/// designs lay over a photo (as opposed to the [kZineTextureCatalog] below,
/// which tints coloured *fallback* surfaces and is chosen per entity).
///
/// Note `cover-texture-01.webp` is the same image inside that catalog; this is
/// the copy the photo surfaces reference, so a designer swapping the grain does
/// not silently re-tint every zine cover keyed to texture `01`.
const String kSokoPaperGrainTexture =
    'assets/images/textures/avatar-texture.png';

/// How much of the grain shows over a photo. Figma lays it in at `opacity-50`
/// with no blend mode on every surface that carries it.
const double kSokoPaperGrainOpacity = 0.5;

/// The creased-paper grain the **Daily Drop** card carries — Figma's
/// `Gstaik Textures (5) 3` on frame `7675:37837`.
///
/// A different sheet from [kSokoPaperGrainTexture]: that one is a fine even
/// grain laid over *photos*, this one has visible creases and folds and is laid
/// over a *flat colour field*, which is what makes the card read as printed
/// card stock rather than as a coloured rectangle.
///
/// Identified by correlating the Figma export against all 30 bundled textures
/// — `cover-texture-03.webp` returns **0.97**, the runner-up 0.25 — the same
/// method that pinned [kSokoPaperGrainTexture]. Referenced by path rather than
/// by its `kZineTextureCatalog` id `'03'` for that constant's reason: swapping
/// the card grain must not re-tint every zine cover seeded to texture 3.
///
/// ## ⚠️ This renders SUBTLER than the Figma frame, on purpose
///
/// The bundled file is **371 × 512**; Figma's source sheet is **2173 × 3000**.
/// The card magnifies the sheet ~5×, so the fine grain averages away and only
/// the coarse creases survive. Measured on the card's bare field, Figma's own
/// render carries a grain amplitude of **4.77** (sd of high-frequency detail,
/// 0–255) and ours **0.95** — about a fifth.
///
/// **The compositing is not the cause.** At the frame's own `opacity-40` our
/// render sat within measurement noise of the CSS formula — the blend and the
/// opacity were already right, which is why raising
/// [kSokoRitualCardTextureOpacity] past 0.4 (which we since have, by decision)
/// does not restore the missing grain: the high frequencies are gone from the
/// asset, so more opacity only deepens the coarse creases that survived.
///
/// The only real fix is a higher-resolution sheet, and it is expensive: grain
/// is noise, and noise does not compress (baking the alpha away changes
/// nothing). Shipping just the window the card actually shows costs **152 KB
/// for 53 %** of Figma's grain, **357 KB for 78 %**, **918 KB for 91 %**.
/// **Zé chose to stay at 36 KB (2026-09-01)** rather than add one of the app's
/// largest assets for a background texture. Revisit only with that price in
/// hand — see D308.
const String kSokoDailyDropCardTexture =
    'assets/images/textures/cover-texture-03.webp';

/// The **Weekly Bundle** card's grain — Figma's `Texturelabs_Grunge_340S 2` on
/// frame `7675:37872`. A fine even grain, where the Daily Drop's sheet is
/// creased and folded; the two cards are deliberately different paper.
///
/// **Added rather than reused, because it is not one of ours.** The same search
/// that matched the Daily Drop sheet at 0.97 tops out at **0.13** here across
/// all 30 bundled textures, under squash, centre-crop, every 90° rotation and
/// mirroring. ⚠️ Do not be misled by `SokoGrungeSurface`, which used to name
/// `avatar-texture.png` "Texturelabs Grunge 340S": that file correlates
/// **0.04** with this sheet and is in fact the Gstaik paper grain.
///
/// Unlike [kSokoDailyDropCardTexture] this one is **not** resolution-starved:
/// 960 × 595 is the original Figma upload, and the card asks for ~1198 × 742 at
/// 3× — a 1.25× magnification rather than a 5× one. There is no sharper source
/// to reach for, so this ships at full available fidelity.
const String kSokoWeeklyBundleCardTexture =
    'assets/images/textures/grunge-texture-340s.webp';

/// How much of a ritual card's grain shows over its colour field.
///
/// Hard Light against a solid field is what makes a mid-grey grain read as a
/// *fold* in the colour instead of a grey film over it — see `BlendMask`, which
/// is how the blend reaches Flutter.
///
/// **0.55, deliberately over Figma's `opacity-40`** (Zé, 2026-09-01: *"put the
/// texture slightly less transparent … so that it is more noticeable"*). Do not
/// "correct" this back to 0.4 to match the frames — the divergence is the
/// decision, and the reason is [kSokoDailyDropCardTexture]'s resolution note:
/// at 0.4 our Daily Drop grain measures ~1.1 against Figma's 4.8, because the
/// bundled sheet is a ~5× magnification and the fine grain is gone from the
/// file. Opacity cannot bring that grain back — it only deepens the coarse
/// creases that survived — but it does make the paper read, which is what was
/// asked for.
///
/// Measured amplitude at this value: Daily Drop **1.45** (was 1.09), Weekly
/// Bundle **2.81** (was 2.06). The two differ at the same opacity because the
/// Weekly sheet is opaque and adequately sized while the Daily Drop's carries a
/// mean alpha of 0.28 and is resolution-starved.
const double kSokoRitualCardTextureOpacity = 0.55;

/// Bundled cover textures by catalog id. The id ([String]) is what the
/// BE persists in `user_lists.cover_texture`; new textures can be added
/// without a BE migration. All entries are alpha-preserving WebP files
/// designed to overlay coloured surfaces without obscuring foreground.
///
/// Adding a new texture: drop the asset under
/// `assets/images/textures/`, register it here, and the catalog picks
/// it up everywhere — change-cover sheet picker, random-at-create,
/// fallback logic, and the card fallback floor.
const Map<String, String> kZineTextureCatalog = <String, String>{
  '01': 'assets/images/textures/cover-texture-01.webp',
  '02': 'assets/images/textures/cover-texture-02.webp',
  '03': 'assets/images/textures/cover-texture-03.webp',
  '04': 'assets/images/textures/cover-texture-04.webp',
  '05': 'assets/images/textures/cover-texture-05.webp',
  '06': 'assets/images/textures/cover-texture-06.webp',
  '07': 'assets/images/textures/cover-texture-07.webp',
  '08': 'assets/images/textures/cover-texture-08.webp',
  '09': 'assets/images/textures/cover-texture-09.webp',
  '10': 'assets/images/textures/cover-texture-10.webp',
  '11': 'assets/images/textures/cover-texture-11.webp',
  '12': 'assets/images/textures/cover-texture-12.webp',
  '13': 'assets/images/textures/cover-texture-13.webp',
  '14': 'assets/images/textures/cover-texture-14.webp',
  '15': 'assets/images/textures/cover-texture-15.webp',
  '16': 'assets/images/textures/cover-texture-16.webp',
  '17': 'assets/images/textures/cover-texture-17.webp',
  '18': 'assets/images/textures/cover-texture-18.webp',
  '19': 'assets/images/textures/cover-texture-19.webp',
  '20': 'assets/images/textures/cover-texture-20.webp',
  '21': 'assets/images/textures/cover-texture-21.webp',
  '22': 'assets/images/textures/cover-texture-22.webp',
  '23': 'assets/images/textures/cover-texture-23.webp',
  '24': 'assets/images/textures/cover-texture-24.webp',
  '25': 'assets/images/textures/cover-texture-25.webp',
  '26': 'assets/images/textures/cover-texture-26.webp',
  '27': 'assets/images/textures/cover-texture-27.webp',
  '28': 'assets/images/textures/cover-texture-28.webp',
  '29': 'assets/images/textures/cover-texture-29.webp',
};

/// Deterministic-iteration view over [kZineTextureCatalog] used by the
/// missing-texture fallback (PROD-1918). Declared explicitly so
/// adding/removing entries in the catalog is a one-line, intentional
/// change rather than an accidental reshuffle of which seed maps to which
/// texture.
const List<String> kZineTextureKeys = <String>[
  '01', '02', '03', '04', //
  '05', '06', '07', '08', '09', '10', //
  '11', '12', '13', '14', '15', '16', //
  '17', '18', '19', '20', '21', '22', //
  '23', '24', '25', '26', '27', '28', '29', //
];

/// Documented "safe" texture id pointed at the first shipped texture.
/// Last-resort fallback when [kZineTextureKeys] is empty.
const String kZineDefaultTextureId = '01';

/// Deterministically pick a texture asset path for [seed] (e.g. a venue
/// or event id). Same seed → same texture across devices and refreshes
/// (SHA-1 based, platform-stable). Mirrors the zine resolver's
/// missing-texture fallback formula so card floors and zine covers draw
/// from the same catalog the same way.
String sokoTextureForSeed(String seed) {
  final keys = kZineTextureKeys.isEmpty
      ? const <String>[kZineDefaultTextureId]
      : kZineTextureKeys;
  final String id = keys[stableHash(seed) % keys.length];
  return kZineTextureCatalog[id] ?? kZineTextureCatalog[kZineDefaultTextureId]!;
}

/// A decorative Soko texture sheet, which **degrades to nothing** if the asset
/// cannot be loaded.
///
/// Every grain in this file is a *finish*, not content: it dresses a surface
/// that is already complete without it. A bare `Image` is the wrong shape for
/// that, because Flutter's default error widget is a red cross with the
/// exception text painted across the whole box — so a sheet that fails to load
/// does not remove a texture, it destroys the card wearing it.
///
/// That is not hypothetical, and it does not require the asset to be missing
/// from the repo. Flutter builds the **asset manifest at build time**, so a
/// sheet added by someone else's commit is absent from a dev server that was
/// already running when you pulled it: `Unable to load asset:
/// "assets/images/textures/grunge-texture-340s.webp"`, and the Weekly Bundle
/// card comes up as a red cross (Zé, 2026-09-01 — the fix there is to restart
/// the dev server; the fix here is to not let it look like a broken card).
///
/// [fit] defaults to `fill` because these rects ARE the sheet's own rect —
/// see `RitualCardTexture`.
Widget sokoTextureImage(String asset, {BoxFit fit = BoxFit.fill}) => Image(
  image: AssetImage(asset),
  fit: fit,
  // The surface underneath is intact; show it rather than an error over it.
  errorBuilder: (_, _, _) => const SizedBox.shrink(),
);
