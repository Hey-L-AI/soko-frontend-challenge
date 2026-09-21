import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/social_proof.dart';
import '../../../providers/location_provider.dart';
import '../../../shared/utils/user_location_marker.dart';
import '../../../shared/utils/map_pin_assets.dart';
import '../../../shared/widgets/mapbox_map_widget.dart';

/// Square Mapbox tile sitting between the action grid and the "Aparece em"
/// shelf. Locked-by-default with the activation chip; once unlocked, the
/// fit-all + my-location buttons (rendered by [MapboxMapWidget] itself) and
/// the blue user-location dot appear. 15 px gutters handled by the screen-
/// level padding so the tile aligns with the rest of the column;
/// AspectRatio(1) keeps it square at any content width. Hidden when no
/// coordinates.
class VenueMapBlock extends ConsumerWidget {
  final VenueDetailResponse venue;

  const VenueMapBlock({super.key, required this.venue});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lat = venue.latitude;
    final lng = venue.longitude;
    if (lat == null || lng == null) return const SizedBox.shrink();

    // PROD-2205-followup r4: the detail-page pin IS the focus of
    // the page, so it picks up the same selection treatment as the
    // highlighted pin on the zine item-page map — bigger radius +
    // 3 px darker stroke. Visual continuity across the two surfaces.
    const venuePinId = 'venue-detail-pin';
    final markers = <MapMarker>[
      MapMarker.pin(
        id: venuePinId,
        lat: lat,
        lng: lng,
        color: AppColors.sokoInk,
        category: MapMarkerCategory.venue,
        // PROD-3830: teardrop from the venue's facet (null → pink default).
        // `color` is inert under `categoryIcons`; kept for the non-icon path.
        iconImage: mapPinKey(primaryFacet: venue.primaryFacet),
      ),
    ];

    appendUserLocationMarker(markers, ref.watch(locationProvider));

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: 1,
        child: MapboxMapWidget(
          markers: markers,
          centerLat: lat,
          centerLng: lng,
          zoom: 15,
          fitMarkers: true,
          interactive: true,
          // PROD-2205-followup: chip gated behind kListMapsStaticByDefault.
          staticByDefault: kListMapsStaticByDefault,
          // PROD-2016: route through the cluster source-layer path
          // (single rendering pipeline; legacy DOM-overlay retired).
          // Tooltip disabled — the page IS the detail.
          cluster: true,
          enableTooltip: false,
          // PROD-3830: facet teardrop pin — see the event block's twin. Full
          // asset set + `mapPinKey(primaryFacet:)` so PROD-3832 lights it up
          // with no app release.
          categoryIcons: true,
          categoryIconAssets: kMapPinAssets,
          showPinCaptions: false,
          pinIconSizeStops: MapPinIconTokens.compactIconSizeStops,
          // PROD-2205-followup r4: highlight the page's pin so it
          // matches the focused-pin look from the zine item page.
          selectedMarkerIds: const <String>{venuePinId},
          // Fit-all stays on even for a single pin so the user can
          // reset framing after panning/zooming away. The widget's
          // bbox computation excludes `MapMarker.userLocation`
          // (mapbox_map_web.dart:700), so fit-all snaps back to the
          // venue pin alone — the blue dot never distorts framing.
          showFitAllButton: true,
          showMyLocationButton: true,
          boundsConfig: MapBoundsConfig.detailDefault,
        ),
      ),
    );
  }
}
