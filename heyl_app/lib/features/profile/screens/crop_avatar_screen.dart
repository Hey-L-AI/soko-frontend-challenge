import 'dart:async';
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../widgets/textured_avatar.dart';

/// One-shot request handed to the crop step: the bytes to crop plus a
/// [Completer] that delivers the cropped result back to the caller.
///
/// Why neither GoRouter `extra` nor `context.push`'s return value is used:
/// on web the router rebuilds its stack whenever the refresh-listenable fires
/// (auth / Siga), and that rebuild both (a) drops a non-serializable
/// `Uint8List` passed via `extra` and (b) resolves an imperative `push`'s
/// return Future to `null` *before* the user finishes cropping. The upload
/// branch then never ran and the "Use photo" result was lost. Passing the
/// bytes in and the result out through this object — which lives in the
/// ProviderContainer — is immune to the rebuild.
class AvatarCropRequest {
  AvatarCropRequest(this.bytes);

  final Uint8List bytes;
  final Completer<Uint8List?> _result = Completer<Uint8List?>();

  /// Completes with the cropped PNG bytes, or null if the user cancelled.
  Future<Uint8List?> get result => _result.future;

  void complete(Uint8List? value) {
    if (!_result.isCompleted) _result.complete(value);
  }
}

/// Set by the edit-profile screen right before it pushes
/// [AppRoutes.editProfileCrop]; read once by [CropAvatarScreen].
final avatarCropRequestProvider = StateProvider<AvatarCropRequest?>(
  (ref) => null,
);

/// Crop step shown after picking an avatar, before upload. Pure-Dart cropper
/// (works on web + native). Delivers the cropped bytes via the
/// [AvatarCropRequest] completer (null if the user cancels).
///
/// The frame is the app's rounded square, matching the avatar's shape
/// everywhere, so what you line up is what gets kept — see
/// [_CropAvatarScreenState].
class CropAvatarScreen extends ConsumerStatefulWidget {
  const CropAvatarScreen({super.key});

  @override
  ConsumerState<CropAvatarScreen> createState() => _CropAvatarScreenState();
}

class _CropAvatarScreenState extends ConsumerState<CropAvatarScreen> {
  final _controller = CropController();
  bool _cropping = false;
  AvatarCropRequest? _req;

  static const _bg = Color(0xFF1A1013);

  /// Outline of the viewfinder, and the scrim over everything outside it.
  ///
  /// The package only knows two mask shapes, rectangle and circle, and the
  /// avatar is neither — so [_RoundedFrameOverlay] paints the rounded corners
  /// (scrim + pink outline) on top of the package's square mask.
  static const _frameStroke = 2.0;
  static const _maskColor = Color(0x8C000000); // black @ 55%

  @override
  void initState() {
    super.initState();
    _req = ref.read(avatarCropRequestProvider);
    // Direct hit / refresh with no request → nothing to crop; leave.
    if (_req == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  void dispose() {
    // If we leave without a successful crop (Cancel / back / router bounce),
    // release the awaiting caller with null so it doesn't hang.
    _req?.complete(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final req = _req;
    if (req == null) return const ColoredBox(color: _bg);
    final l10n = Lt.of(context);
    return ColoredBox(
      color: _bg,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(
                children: [
                  TextButton(
                    // Never disabled: if `onCropped` never fires (a decode
                    // failure the package swallows), a Cancel gated on
                    // `_cropping` leaves the screen with no way out but a
                    // page reload.
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      l10n.profileCropCancel,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    l10n.profileCropTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 72),
                ],
              ),
            ),
            Expanded(
              // Breathing room so the frame doesn't sit flush against the
              // screen edge, where a drag would start the platform's
              // back-swipe instead of panning the photo.
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                // Fixed frame, moving photo — the avatar cropper people
                // already know from Instagram / WhatsApp: drag to pan, pinch or
                // scroll to zoom, and the frame never moves.
                //
                // It replaced a drag-the-square-over-a-static-photo model that
                // was a broken hybrid. `interactive` gates panning AND the
                // rect-drag layer (`crop.dart:669`) but NOT the scroll handler
                // (`crop.dart:621` → `_handlePointerSignal`), so a trackpad
                // scroll over the crop area zoomed the photo unasked and
                // nothing could pan it back; the square then had no room left
                // and the corner dots, ratio-locked to 1:1, had none either.
                // Hence "I can't move the square and the dots don't work".
                // Session-replay: mask the user's photo while it's being
                // cropped in native recordings. See posthog_service.dart and
                // auth_shell.dart.
                child: PostHogMaskWidget(
                  child: Crop(
                    image: req.bytes,
                    controller: _controller,
                    // The avatar is a rounded square everywhere in the app, so
                    // the viewfinder is too — the frame has to show exactly what
                    // will be kept, or the app re-crops on render and the user's
                    // framing is only a suggestion. (It has been a portrait
                    // 100×125 frame and then a circle, each matching the avatar's
                    // shape at the time.)
                    //
                    // 1:1 here, rounded corners in the overlay: the package masks
                    // either a rectangle or a circle and nothing in between, and
                    // the ratio is what actually governs the crop — the corner
                    // radius is presentation, applied when the avatar renders.
                    aspectRatio: 1,
                    // Pan + zoom the image. Also makes the scroll-wheel zoom
                    // intentional rather than a side effect.
                    interactive: true,
                    // The frame is the viewfinder, not a handle. With
                    // `interactive` on, the package drops the rect-drag layer
                    // anyway; this also removes the resize, so there is one
                    // gesture to learn instead of three.
                    fixCropRect: true,
                    baseColor: _bg,
                    maskColor: _maskColor,
                    // No corner dots: nothing to grab on a fixed frame, and dots
                    // that cannot be dragged are worse than none.
                    //
                    // This has to be said explicitly. `fixCropRect` only drops the
                    // drag HANDLER; the package still paints `const DotControl()`
                    // whenever `cornerDotBuilder` is null (`crop.dart:698`), so
                    // the dots were being drawn all along.
                    cornerDotBuilder: (size, alignment) =>
                        const SizedBox.shrink(),
                    overlayBuilder: (context, rect) =>
                        const IgnorePointer(child: _RoundedFrameOverlay()),
                    onCropped: (result) {
                      if (!mounted) return;
                      switch (result) {
                        case CropSuccess(:final croppedImage):
                          req.complete(croppedImage);
                          Navigator.of(context).maybePop();
                        case CropFailure():
                          setState(() => _cropping = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.profileCropError)),
                          );
                      }
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SokoCtaButton(
                label: l10n.profileCropUse,
                loading: _cropping,
                onPressed: () {
                  setState(() => _cropping = true);
                  _controller.crop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rounded-square viewfinder, painted over the package's square mask.
///
/// Two jobs, both because `crop_your_image` has no rounded-rect mask: darken
/// the four corner slivers that fall OUTSIDE the avatar's radius but inside the
/// package's rectangular hole, and outline what's left in Soko pink. Without
/// the first the frame would promise square corners the avatar then rounds off.
class _RoundedFrameOverlay extends StatelessWidget {
  const _RoundedFrameOverlay();

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _RoundedFramePainter(),
    child: const SizedBox.expand(),
  );
}

class _RoundedFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      // The crop rect is square (aspectRatio: 1), so either side gives the same
      // radius the avatar will use at render time.
      Radius.circular(size.shortestSide * TexturedAvatar.kRadiusRatio),
    );
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(rect),
        Path()..addRRect(rrect),
      ),
      Paint()..color = _CropAvatarScreenState._maskColor,
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _CropAvatarScreenState._frameStroke
        ..color = AppColors.sokoPink,
    );
  }

  @override
  bool shouldRepaint(_RoundedFramePainter oldDelegate) => false;
}
