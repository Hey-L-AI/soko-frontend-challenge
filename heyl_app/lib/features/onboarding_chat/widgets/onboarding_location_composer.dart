import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/location_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../providers/city_auto_scope_provider.dart';
import '../../../providers/location_provider.dart';
import '../../../shared/widgets/soko_tag.dart';
import '../../lists/models/search_scope.dart';
import '../../lists/widgets/location_scope_picker_sheet.dart';

/// A resolved city choice from the onboarding location step.
///
/// [supported] drives the onboarding city gate: `true` when the city is a Soko
/// coverage city (local-sourced and not explicitly `is_open == false`), so the
/// flow continues; `false` routes to the "Não sou local ainda" step.
typedef OnboardingCitySelection = ({
  String displayName,
  String? cityId,
  String? iso2,
  double? latitude,
  double? longitude,
  bool supported,
});

/// Labels a location the way the city step names it: the finest place we know
/// prefixed onto its city — "Alvalade, Lisboa".
///
/// [leaf] is the neighbourhood (the GPS fix's resolved neighbourhood, or the
/// picked area's own leaf name, which `boundaryPlaceLabel` already strips down
/// to just "Alvalade"). It collapses to the bare [city] when there is no leaf,
/// or when the leaf IS the city — a municipality whose finest boundary carries
/// the same name as its city would otherwise render "Sines, Sines". Comparison
/// is case-insensitive and whitespace-trimmed because the two names arrive from
/// different resolvers.
@visibleForTesting
String placeLabel({required String? leaf, required String city}) {
  final trimmed = (leaf ?? '').trim();
  if (trimmed.isEmpty) return city;
  if (trimmed.toLowerCase() == city.trim().toLowerCase()) return city;
  return '$trimmed, $city';
}

/// City-step composer (Figma `Onde vives?`): two right-aligned pills —
/// "A minha localização" (outline → device GPS) and "Escolhe uma localização"
/// (filled → the shared location picker). Both resolve to a [GeoCity] and hand
/// back an [OnboardingCitySelection]. Reuses the same providers as the V6
/// profiling location step (`locationProvider`, `cityAutoScopeProvider`,
/// `showLocationScopePicker`), so behaviour matches the rest of the app.
class OnboardingLocationComposer extends ConsumerStatefulWidget {
  const OnboardingLocationComposer({
    super.key,
    required this.useMyLocationLabel,
    required this.chooseLocationLabel,
    required this.onSelected,
    this.enabled = true,
  });

  final String useMyLocationLabel;
  final String chooseLocationLabel;
  final ValueChanged<OnboardingCitySelection> onSelected;
  final bool enabled;

  @override
  ConsumerState<OnboardingLocationComposer> createState() =>
      _OnboardingLocationComposerState();
}

class _OnboardingLocationComposerState
    extends ConsumerState<OnboardingLocationComposer> {
  bool _busy = false;

  void _trackMethod(String method) {
    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(step: 'identity.city', action: method);
  }

  Future<void> _useMyLocation() async {
    if (!widget.enabled || _busy) return;
    _trackMethod('method_gps');
    setState(() => _busy = true);
    try {
      // `awaitResolvedAdmin` keeps the `PUT /me/location` that follows the fix
      // inside this await, so the city + neighbourhood read below describe THIS
      // fix. Without it the PUT is fire-and-forget and we read whatever an
      // earlier write left in state — in practice the boot `ip_approx` PUT,
      // which supplies its own city and therefore never runs the backend
      // resolver, so it carries a city and no neighbourhood. That is what made
      // this step answer a bare "Lisboa" for a fix inside Alvalade.
      final status = await ref
          .read(locationProvider.notifier)
          .requestPermissionOnly(awaitResolvedAdmin: true);
      if (!mounted) return;

      if (status == LocationPermissionStatus.granted) {
        final state = ref.read(locationProvider);
        final snap = state.lastLocation;
        final city = state.resolvedCityName;
        final hood = state.resolvedNeighborhood;
        // Require the GPS COORDS (not just a reverse-geocoded name): the server
        // now decides supported/unsupported from the coords we send, so a name
        // without coords is useless for routing. This also sidesteps the old
        // reverse-geocode race — coords are available synchronously from the
        // snapshot, the name is not.
        if (snap != null && city != null && city.isNotEmpty) {
          widget.onSelected((
            displayName: placeLabel(leaf: hood, city: city),
            cityId:
                null, // GPS carries no seeded GeoCity id — coords resolve it.
            iso2: null,
            latitude: snap.lat,
            longitude: snap.lon,
            // Hint only — the server re-resolves coverage from the coords above
            // and overrides the branch. We do NOT fail open on the client here
            // (the old `isCurrentCitySupportedProvider ?? true` routed uncovered
            // GPS fixes into the supported branch → empty zines).
            supported: true,
          ));
          return;
        }
      }
      // Denied, no coords, or unresolved → fall back to the manual picker
      // (already counted as a GPS attempt, so don't also emit a `method_picker`).
      await _choose(viaFallback: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose({bool viaFallback = false}) async {
    if (!widget.enabled) return;
    if (!viaFallback) {
      _trackMethod('method_picker');
      // Product ask: request the OS location permission on tap of BOTH pills,
      // not only the GPS one. The manual picker doesn't need a fix — we prompt,
      // then open the picker regardless of the outcome. Skip when this is the
      // GPS-denied fallback (`_useMyLocation` already prompted) so we never
      // double-prompt.
      await ref.read(locationProvider.notifier).requestPermissionOnly();
      if (!mounted) return;
    }
    final autoScope = await ref.read(cityAutoScopeProvider.future);
    if (!mounted) return;
    final picked = await showLocationScopePicker(
      context,
      ref,
      currentScope: autoScope,
    );
    if (!mounted || picked == null) return;
    final selection = cityScopeSelection(picked);
    if (selection != null) {
      final city = selection.city;
      // Label the answer with the place the user actually picked. An area pick
      // (e.g. Arroios) resolves to its *containing* coverage city (Lisboa) —
      // `cityScopeSelection` returns that city so it can supply the `cityId` +
      // the supported gate (see `SearchScopeArea.city`, which is the city "only
      // to supply the city_id"). But showing bare `city.name` dropped the
      // neighbourhood the user selected ("Arroios" → "Lisboa"). `placeLabel`
      // composes "Arroios, Lisboa" — the same helper the GPS path uses, so both
      // pills name a place identically — and keeps the bare city for a
      // whole-city pick (not an area, or an area whose leaf name is the city).
      final areaName = picked is SearchScopeArea
          ? picked.displayName.trim()
          : '';
      final displayName = placeLabel(leaf: areaName, city: city.name);
      widget.onSelected((
        displayName: displayName,
        cityId: city.id,
        iso2: selection.iso2,
        latitude: city.latitude,
        longitude: city.longitude,
        // Supported = a Soko coverage city: local-sourced and not explicitly
        // closed. Google-sourced picks (no local coverage) route to not-local.
        supported: city.isLocalSourced && (city.isOpen ?? true),
      ));
      return;
    }

    // The pick resolved to no seeded coverage city — e.g. New York, or a point
    // with no containing boundary. Still let the user choose it: record the
    // area's label + centre and mark it unsupported so the gate routes it to
    // the not-local branch instead of silently doing nothing.
    if (picked is SearchScopeArea) {
      widget.onSelected((
        displayName: picked.displayName,
        cityId: null,
        iso2: picked.city?.countryCode,
        latitude: picked.centerLat,
        longitude: picked.centerLng,
        supported: false,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Right-aligned, content-width pills — Figma `7285:23244`: gap 6, Soko/Paper
    // outline by default, Soko/Pink fill on press/hover.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        _LocationPill(
          label: widget.useMyLocationLabel,
          busy: _busy,
          onTap: widget.enabled ? _useMyLocation : null,
        ),
        const SizedBox(height: 6),
        _LocationPill(
          label: widget.chooseLocationLabel,
          onTap: widget.enabled && !_busy ? _choose : null,
        ),
      ],
    );
  }
}

/// Soko/Paper outline by default; Soko/Pink fill on press/hover (the design's
/// pressed state).
class _LocationPill extends StatefulWidget {
  const _LocationPill({
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  State<_LocationPill> createState() => _LocationPillState();
}

class _LocationPillState extends State<_LocationPill> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final active = enabled && (_pressed || _hovered);
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: active ? AppColors.sokoPink : AppColors.sokoPaper,
              border: Border.all(color: AppColors.sokoPink),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: widget.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.sokoInk,
                    ),
                  )
                : Text(widget.label, style: SokoTag.textStyle),
          ),
        ),
      ),
    );
  }
}
