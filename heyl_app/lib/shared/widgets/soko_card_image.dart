import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/soko_texture.dart';
import '../../data/models/saved_item.dart';
import 'cached_image.dart';

/// How long the fallback floor stays fully transparent before it begins
/// to fade in, on a url-bearing card's FIRST appearance. Gives the network
/// image a window to land first, so a grid of cards doesn't flash
/// all-blue/all-green before photos arrive.
const Duration kSokoFloorHold = Duration(milliseconds: 750);

/// How long the fallback floor takes to fade from transparent to full
/// opacity once the hold elapses (url-card first appearance).
const Duration kSokoFloorFade = Duration(milliseconds: 1500);

/// How long content fades in: the photo once it decodes, and the no-image
/// floor on a card's first appearance. Repeat appearances snap (no fade).
const Duration kSokoImageFade = Duration(milliseconds: 350);

/// Seeds whose card has been shown at least once this session. Mirrors the
/// image cache: the first time a card appears it fades in; on every repeat
/// appearance it snaps instantly with no animation. In-memory only, so it
/// resets on app restart — the same lifetime semantics as the image cache.
final Set<String> _sokoSeenSeeds = <String>{};

/// Clears the session seen-seed set. Test-only.
@visibleForTesting
void debugResetSokoSeenSeeds() => _sokoSeenSeeds.clear();

/// The kind of entity a card represents — drives the fallback floor
/// colour. Place/venue → blue, event → green, anything else → neutral.
enum SokoEntityKind {
  venue,
  event,
  neutral;

  Color get floorColor => switch (this) {
    SokoEntityKind.venue => AppColors.sokoVenue,
    SokoEntityKind.event => AppColors.sokoEvent,
    SokoEntityKind.neutral => AppColors.sokoShade5,
  };

  /// Map a raw `type` string (`ItemSuggestion`/`PlaceSuggestion`/
  /// `CardItem` carry `'place'` / `'event'` / `'generic'`).
  static SokoEntityKind fromTypeString(String? type) {
    switch (type) {
      case 'event':
        return SokoEntityKind.event;
      case 'place':
      case 'venue':
        return SokoEntityKind.venue;
      default:
        return SokoEntityKind.neutral;
    }
  }

  /// Map a [SavedItemType] (used by `SavedItem` and `UserListItem`).
  static SokoEntityKind fromSavedType(SavedItemType type) =>
      type == SavedItemType.event ? SokoEntityKind.event : SokoEntityKind.venue;
}

/// Canonical venue/event card image.
///
/// Renders a Soko brand-colour "floor" (type-aware: blue venues, green
/// events) with a deterministic paper texture seeded by [seed], and lays
/// the network photo on top. Behaviour:
///
/// * **No image** (`imageUrl` null/empty, 404, network error, timeout):
///   the floor + texture is the card visual — never a broken-image icon.
/// * **The photo renders natively** via [CachedImage] — it snaps in
///   instantly when the bytes are already cached and fades in when they
///   arrive over the network. Crucially its visibility is NOT gated on
///   any local flag, so a photo that exists always paints once loaded
///   (the floor is a pure backdrop beneath it). The texture sits *beneath*
///   the photo, so it is only ever visible in the no-image fallback — a
///   loaded opaque `BoxFit.cover` photo fully occludes it. (Venue/event
///   photos are opaque JPEG/WebP, so this holds.)
/// * **Floor reveal** — the backdrop's own fade:
///   - *First appearance of a [seed] this session*: a url-bearing card
///     holds the floor transparent for [holdDuration] then fades it in, so
///     a slow/404 photo reveals the brand colour instead of a blank/broken
///     card without flashing colour before a fast photo lands. A no-image
///     card simply fades the floor in over [kSokoImageFade] (no hold).
///   - *Repeat appearance* (the [seed] has been shown before — scrolled
///     away and back): the floor snaps in with no animation, mirroring how
///     a cached photo appears with no fade. Tracked via a session seen-seed
///     set so behaviour is deterministic regardless of how the carousel
///     recycles its card widgets.
class SokoCardImage extends StatefulWidget {
  /// Photo URL. Null or empty → floor + texture only.
  final String? imageUrl;

  /// Deterministic seed — pass the entity id. Drives both texture
  /// selection and the first-appearance/repeat-appearance animation gate;
  /// fall back to name/title at the call site when no id is available.
  final String seed;

  /// Drives the floor colour.
  final SokoEntityKind kind;

  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  /// Fit for the photo (default cover). Pass `contain` for full-bleed
  /// lightboxes and set [showTexture] false there.
  final BoxFit fit;

  /// Whether to overlay the paper texture on the floor. Default true.
  final bool showTexture;

  /// Paint the photo instantly with no fade when its bytes are already warm
  /// (memory cache) — for a tile that is a **Hero-flight destination**.
  ///
  /// The default [CachedImage] path re-runs `CachedNetworkImage`'s ~500 ms
  /// placeholder→image fade every time it mounts, even on a cached image
  /// (the provider resolves a frame late). At the end of a Hero flight that
  /// makes the crisp flown poster drop back to the brand floor for a frame
  /// and fade in again — the reported "snap at the finish". With [instant] the
  /// warmed bytes (see `warmHeroImage`) paint synchronously on the first
  /// frame, pixel-identical to the flight shuttle, so the poster lands
  /// seamlessly. A genuinely cold load (deep-link, cache miss) still fades in.
  final bool instant;

  /// How long the floor stays transparent before fading in, on a
  /// url-bearing card's first appearance. Defaults to [kSokoFloorHold];
  /// pass something shorter for a large hero where a blank hold reads as
  /// sluggish.
  final Duration holdDuration;

  /// Fired (post-frame) once the photo has painted. Forwarded to [CachedImage]
  /// — lets a parent gate an overlay (e.g. a timing chip) on the poster
  /// loading. Never fires for a no-image card.
  final VoidCallback? onLoaded;

  const SokoCardImage({
    super.key,
    required this.imageUrl,
    required this.seed,
    required this.kind,
    this.width,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
    this.showTexture = true,
    this.instant = false,
    this.holdDuration = kSokoFloorHold,
    this.onLoaded,
  });

  @override
  State<SokoCardImage> createState() => _SokoCardImageState();
}

class _SokoCardImageState extends State<SokoCardImage>
        // TickerProviderStateMixin (not SingleTicker…): the carousel/list recycles
        // this State for a new item (didUpdateWidget), which disposes the old floor
        // controller and creates a fresh one — a second ticker over the State's
        // lifetime, which SingleTickerProviderStateMixin forbids (it asserted
        // "multiple tickers were created"). Only ever one is live at a time.
        with
        TickerProviderStateMixin {
  AnimationController? _floorController;
  Animation<double>? _floorReveal;

  /// True when the floor should render instantly with no animation (repeat
  /// appearance of a seen seed). Decided at configure time.
  bool _instantFloor = false;

  bool get _hasImage => widget.imageUrl?.isNotEmpty ?? false;

  @override
  void initState() {
    super.initState();
    _configureReveal();
  }

  @override
  void didUpdateWidget(SokoCardImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The carousel reuses a card's State for a different item as it
    // recycles widgets. Re-derive the floor reveal whenever the identity
    // or has-image state changes so it follows the new item, not the
    // recycled predecessor. (The photo itself is rendered by CachedImage,
    // which keys on imageUrl and updates on its own.)
    final hadImage = oldWidget.imageUrl?.isNotEmpty ?? false;
    if (oldWidget.seed != widget.seed ||
        hadImage != _hasImage ||
        oldWidget.holdDuration != widget.holdDuration) {
      _disposeController();
      _configureReveal();
    }
  }

  void _configureReveal() {
    final seenBefore = _sokoSeenSeeds.contains(widget.seed);
    _sokoSeenSeeds.add(widget.seed);

    if (seenBefore) {
      // Repeat appearance → snap the floor in (a cached photo, if any,
      // covers it instantly anyway).
      _instantFloor = true;
      return;
    }

    _instantFloor = false;
    if (_hasImage) {
      // Hold the floor transparent, then ease it in — so a fast photo
      // covers a still-transparent floor (no colour flash) while a
      // slow/404 photo reveals the brand colour underneath.
      final total = widget.holdDuration + kSokoFloorFade;
      final holdFraction = total.inMicroseconds == 0
          ? 0.0
          : widget.holdDuration.inMicroseconds / total.inMicroseconds;
      _startReveal(total, Interval(holdFraction, 1.0, curve: Curves.easeOut));
    } else {
      // No photo will arrive — nothing to wait for, so fade the floor
      // straight in at the same speed a photo would (no hold).
      _startReveal(kSokoImageFade, Curves.easeOut);
    }
  }

  void _startReveal(Duration duration, Curve curve) {
    _floorController = AnimationController(vsync: this, duration: duration);
    _floorReveal = CurvedAnimation(parent: _floorController!, curve: curve);
    _floorController!.forward();
  }

  void _disposeController() {
    _floorController?.dispose();
    _floorController = null;
    _floorReveal = null;
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final instant = _instantFloor || reduceMotion;
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;

    // Floor + texture backdrop. Snap/reduce-motion paint it at full
    // opacity; a first-appearance card reveals it via the controller.
    Widget floor = _floor(dpr);
    if (!instant && _floorReveal != null) {
      floor = FadeTransition(opacity: _floorReveal!, child: floor);
    }

    final children = <Widget>[floor];
    if (_hasImage) {
      // Native rendering: snaps if cached, fades if it arrives over the
      // network, and never paints when it fails (transparent errorWidget →
      // the floor stays). Visibility is owned by CachedImage, not a local
      // flag, so an existing photo always paints once loaded.
      children.add(
        widget.instant
            ? _instantPhoto()
            : CachedImage(
                imageUrl: widget.imageUrl!,
                fit: widget.fit,
                placeholder: const SizedBox.expand(),
                errorWidget: const SizedBox.expand(),
                onLoaded: widget.onLoaded,
              ),
      );
    }

    Widget content = Stack(fit: StackFit.expand, children: children);
    if (widget.borderRadius != null) {
      content = ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }

    return RepaintBoundary(
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: content,
      ),
    );
  }

  /// Hero-landing photo: the EXACT SAME `Image(CachedNetworkImageProvider,
  /// gaplessPlayback)` — with no fade — that the flight shuttle
  /// (`detailPhotoHeroFlightShuttle`) paints, so the handoff at flight end is
  /// pixel-continuous. Deliberately **no `frameBuilder` fade**: on web
  /// `wasSynchronouslyLoaded` is almost always false even for a warm image
  /// (web decodes async), so any fade path there re-fades the just-flown poster
  /// and reintroduces the "snap at the finish". A warm image paints on frame 1;
  /// a cold one paints when it decodes (the [SokoCardImage] floor shows through
  /// until then); a failure paints nothing and the floor stays.
  Widget _instantPhoto() {
    return Image(
      image: CachedNetworkImageProvider(widget.imageUrl!),
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: widget.onLoaded == null
          ? null
          : (context, child, frame, wasSyncLoaded) {
              if (wasSyncLoaded || frame != null) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => widget.onLoaded!(),
                );
              }
              return child;
            },
      errorBuilder: (_, __, ___) => const SizedBox.expand(),
    );
  }

  Widget _floor(double dpr) {
    final Color color = widget.kind.floorColor;
    if (!widget.showTexture) {
      return ColoredBox(color: color);
    }
    return ColoredBox(
      color: color,
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Downscale the texture decode to the painted size so a 44px
            // thumbnail doesn't hold a full-res WebP in the image cache.
            final double w = constraints.maxWidth;
            final int? cacheWidth = (w.isFinite && w > 0)
                ? (w * dpr).round()
                : null;
            return Image.asset(
              sokoTextureForSeed(widget.seed),
              fit: BoxFit.cover,
              cacheWidth: cacheWidth,
            );
          },
        ),
      ),
    );
  }
}
