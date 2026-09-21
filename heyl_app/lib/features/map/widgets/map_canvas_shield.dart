import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

/// The full-bleed Mapbox-canvas shield (a [PointerInterceptor], so it blocks
/// the HTML platform view underneath — a plain Flutter widget can't).
///
/// It stays mounted for a short grace period AFTER [active] flips false:
/// on touch browsers a tap fires `touchend` (which Flutter's modal barrier
/// handles — closing the sheet and dropping the shield) and the browser then
/// dispatches its compatibility `mousedown`/`mouseup`/`click` up to ~300ms
/// later, RE-HIT-TESTED at dispatch time. Without the linger those land on
/// the freshly re-exposed Mapbox canvas, so the very tap that closed a pin's
/// detail sheet immediately opened the next pin's (mobile-web only — desktop
/// mouse events all dispatch while the shield is still mounted). The cost is
/// an inert map for [_MapCanvasShieldState._lingerMs] after a sheet closes —
/// imperceptible.
///
/// Two independent instances live on the Map page: the modal shield in
/// `map_screen.dart` (gated on `mapModalOpenProvider`) and the focused-search
/// shield inside `MapSearchFocusedOverlay` (PROD-3496 — deliberately NOT
/// driven through `mapModalOpenProvider`, whose writers flip it in `finally`
/// blocks around short-lived sheets).
class MapCanvasShield extends StatefulWidget {
  const MapCanvasShield({super.key, required this.active});

  /// Whether a map modal is currently open (the shield's steady state).
  final bool active;

  @override
  State<MapCanvasShield> createState() => _MapCanvasShieldState();
}

class _MapCanvasShieldState extends State<MapCanvasShield> {
  /// Covers the touch→mouse compatibility-event window (≤ ~300ms) with slack.
  static const int _lingerMs = 400;

  Timer? _linger;
  late bool _shown = widget.active;

  @override
  void didUpdateWidget(MapCanvasShield oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      // (Re)opened — cancel any pending drop so a modal reopened within the
      // grace period can't have its shield yanked away mid-flight.
      _linger?.cancel();
      _linger = null;
      if (!_shown) setState(() => _shown = true);
    } else if (_shown && _linger == null) {
      _linger = Timer(const Duration(milliseconds: _lingerMs), () {
        _linger = null;
        if (mounted) setState(() => _shown = false);
      });
    }
  }

  @override
  void dispose() {
    _linger?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The inert branch is a childless box: it takes no DOM element and
    // absorbs no hits (hitTestSelf is false), so map taps pass through.
    return _shown
        ? PointerInterceptor(child: const SizedBox.expand())
        : const SizedBox.shrink();
  }
}
