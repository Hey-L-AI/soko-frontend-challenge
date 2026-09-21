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
///
/// Mirror of `VenueMapBlock` — same visual treatment for both detail
/// surfaces (design doc § 5.3).
class EventMapBlock extends ConsumerWidget {
  final EventDetailResponse2 event;

  const EventMapBlock({super.key, required this.event});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lat = event.latitude;
    final lng = event.longitude;
    if (lat == null || lng == null) return const SizedBox.shrink();

    // PROD-2205-followup r4: the detail-page pin IS the focus of
    // the page, so it picks up the same selection treatment as the
    // highlighted pin on the zine item-page map — bigger radius +
    // 3 px darker stroke. Visual continuity across the two surfaces.
    //
    // Multi-venue event caveat: today only the event's primary
    // venue is rendered. The BE endpoints powering this page
    // (`getEventDetail` → `EventDetailResponse2`, `getEvent` →
    // `EventDetailResponse.occurrences`) don't carry per-occurrence
    // lat/lng — only `venue_id` / `venue_name` per occurrence. To
    // light up every venue of a tour we'd need either coords on
    // each `ListItemEventOccurrence` / `EventOccurrence` or an
    // `occurrence_locations` companion array (mirror of the slim
    // endpoint fix in PROD-2219). Tracked as a parallel BE follow-
    // up.
    const eventPinId = 'event-detail-pin';
    final markers = <MapMarker>[
      MapMarker.pin(
        id: eventPinId,
        lat: lat,
        lng: lng,
        color: AppColors.sokoInk,
        category: MapMarkerCategory.event,
        // PROD-3830: teardrop from the event's facet (null → pink default).
        // `color` is inert under `categoryIcons`; kept for the non-icon path.
        iconImage: mapPinKey(primaryFacet: event.primaryFacet),
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
          // PROD-2016: every map consumer now goes through the
          // cluster source-layer path (legacy DOM-overlay path
          // retired). For a single-pin detail block the cluster
          // never activates — but routing through the same path
          // keeps the codebase to one rendering pipeline.
          cluster: true,
          // Tooltip is intentionally NOT wired on detail blocks:
          // the page IS the detail, so a tooltip duplicates context.
          enableTooltip: false,
          // PROD-3830: facet teardrop pin. One static pin, but the full asset
          // set is still registered and resolved through
          // `mapPinKey(primaryFacet:)` — that is what makes the art appear
          // when PROD-3832 adds the field to the detail response, with no app
          // release.
          categoryIcons: true,
          categoryIconAssets: kMapPinAssets,
          // Captions off — the page already names the event.
          showPinCaptions: false,
          // 1:1 block: the global curve renders ~24×33 px here, noticeably
          // larger than the r10 circle it replaces.
          pinIconSizeStops: MapPinIconTokens.compactIconSizeStops,
          // PROD-2205-followup r4: highlight the page's pin so it
          // matches the focused-pin look from the zine item page.
          selectedMarkerIds: const <String>{eventPinId},
          // Fit-all stays on even for a single pin so the user can
          // reset framing after panning/zooming away. The widget's
          // bbox computation excludes `MapMarker.userLocation`
          // (mapbox_map_web.dart:700), so fit-all snaps back to the
          // event pin alone — the blue dot never distorts framing.
          showFitAllButton: true,
          showMyLocationButton: true,
          boundsConfig: MapBoundsConfig.detailDefault,
        ),
      ),
    );
  }
}
