import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/location_provider.dart';
import '../../map/utils/map_pin_labels.dart' show truncateMapPinTitle;
import '../../../shared/utils/map_pin_assets.dart';
import '../../../shared/widgets/mapbox_map_widget.dart';

/// Map view for displaying list items on a map.
///
/// PROD-2016: pin tap shows an anchored tooltip (item name + type + a
/// "View details" button) rendered by `MapboxMapWidget` itself. The
/// host (this widget) provides the content resolver and the view-
/// details navigation callback. Tap a cluster (when the cluster flag
/// is on) to zoom in. The "fit all" button stays as a way to recover
/// the wide view after panning.
class ListMapView extends ConsumerStatefulWidget {
  final List<UserListItem> items;
  final Function(UserListItem)? onItemTap;
  final Function(UserListItem)? onItemRemove;
  final bool isEditMode;

  /// Optional bounding box to fit on first paint (and on bbox change).
  /// When set, the map fits the rectangle `(south, west)` → `(north, east)`
  /// rather than auto-fitting to the markers. Used by the `/lists` hub
  /// (PROD-1911) to fit a selected city. Falls back to fit-to-markers
  /// when null.
  final BoundingBox? bbox;

  const ListMapView({
    super.key,
    required this.items,
    this.onItemTap,
    this.onItemRemove,
    this.isEditMode = false,
    this.bbox,
  });

  @override
  ConsumerState<ListMapView> createState() => _ListMapViewState();
}

class _ListMapViewState extends ConsumerState<ListMapView> {
  List<UserListItem> get _itemsWithCoordinates => widget.items
      .where((i) => i.latitude != null && i.longitude != null)
      .toList();

  String _indexToLetter(int index) {
    if (index < 0 || index > 25) {
      return (index + 1).toString();
    }
    return String.fromCharCode('A'.codeUnitAt(0) + index);
  }

  /// Build MapMarker list for the Mapbox map
  List<MapMarker> _buildMapMarkers(LocationState locationState) {
    final markers = <MapMarker>[];
    final items = _itemsWithCoordinates;

    // Get theme-aware primary color for markers
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final letter = _indexToLetter(i);

      // PROD-1978: derive semantic category from the heavy item's
      // itemType so the cluster path can color venues blue and events
      // green via the Mapbox match expression. SavedItemType.place maps
      // to MapMarkerCategory.venue (a "place" in our domain is a venue).
      final category = item.itemType == SavedItemType.event
          ? MapMarkerCategory.event
          : MapMarkerCategory.venue;

      markers.add(
        MapMarker.letter(
          id: item.id,
          lat: item.latitude!,
          lng: item.longitude!,
          letter: letter,
          data: item,
          color: primaryColor,
          category: category,
          // PROD-3830: teardrop from the item's facet (null → pink default).
          // `color` is inert under `categoryIcons`; kept for the non-icon path.
          iconImage: mapPinKey(primaryFacet: item.primaryFacet),
          // PROD-3830: captions are ON for this surface, so the markers must
          // actually CARRY the text — `showPinCaptions` only installs the
          // layer; the renderers stamp `pin_title` from `MapMarker.pinTitle`.
          // Without this the list maps would render an empty caption label
          // (placement work for nothing), which is the exact waste
          // PROD-3828 §4's gate was added to avoid.
          //
          // `/map` gets this from `withMapPinLabels(...)`, which is Map-page
          // machinery (it also resolves a localized facet subtitle from the
          // discovery catalog). List items have no facet today, so there is no
          // subtitle to resolve — title only, truncated by the same
          // grapheme cap, because Mapbox symbol text has no max-lines knob.
          pinTitle: (item.title?.trim().isNotEmpty ?? false)
              ? truncateMapPinTitle(item.title!.trim())
              : null,
        ),
      );
    }

    // PROD-1978: surface the user's GPS as a blue dot on the cover map,
    // matching the chat compact map's treatment. Skip IP-fallback (the
    // user's "location" is a city centroid, not a point worth pinning)
    // and skip when GPS hasn't resolved yet.
    final userLoc = locationState.lastLocation;
    if (userLoc != null && !locationState.isIpFallback) {
      markers.add(
        MapMarker.userLocation(
          lat: userLoc.lat,
          lng: userLoc.lon,
          accuracyM: userLoc.accuracyM,
        ),
      );
    }

    return markers;
  }

  /// PROD-2016: resolves the tooltip content for a tapped pin. Returns
  /// null if the marker doesn't map back to a list item — defensive,
  /// shouldn't happen because every list marker carries the
  /// corresponding `UserListItem` in `data`.
  MapPinTooltipContent? _resolveTooltipContent(MapMarker marker) {
    final item = marker.data;
    if (item is! UserListItem) return null;
    final title = item.title;
    if (title == null || title.isEmpty) return null;
    final lt = Lt.of(context);
    final subtitle = item.itemType == SavedItemType.event
        ? lt.eventDetailTagTypeEvent
        : lt.venueDetailTagTypeVenue;
    return MapPinTooltipContent(title: title, subtitle: subtitle);
  }

  /// PROD-2016: the tooltip's "View details" button forwards through
  /// to the host page's `onItemTap` — which already knows whether to
  /// push the standalone or the in-list detail route.
  void _handleViewDetails(MapMarker marker) {
    final item = marker.data;
    if (item is! UserListItem) return;
    widget.onItemTap?.call(item);
  }

  @override
  Widget build(BuildContext context) {
    // PROD-1805: gracefully handle empty lists — when the host passes
    // zero items AND no bbox to anchor the camera, there's nothing to
    // show. Return SizedBox.shrink() so the surrounding section
    // collapses instead of rendering an empty Lisbon-centered map that
    // looks like a load error. (Callers like the list cover and list
    // view body already guard via `mapPinItems.isNotEmpty`, but the
    // lists-hub map passes a bbox and that path still renders.)
    if (widget.items.isEmpty && widget.bbox == null) {
      return const SizedBox.shrink();
    }

    final items = _itemsWithCoordinates;
    final hasItems = items.isNotEmpty;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final locationState = ref.watch(locationProvider);
    final markers = _buildMapMarkers(locationState);

    // Default center (Lisbon).
    const defaultLat = 38.7223;
    const defaultLng = -9.1393;

    // When the host passes a bbox, fit the map to the bbox rectangle
    // rather than auto-fitting to the markers. When the list is
    // empty, a bbox is the only way to position the camera
    // meaningfully — fall back to the default centroid otherwise.
    final bbox = widget.bbox;
    final shouldFitBbox = bbox != null;

    // No drawer now — only reserve room for the floating bottom nav.
    // PROD-1978 Phase 5: removing the card drawer reclaims this space
    // for the IP-fallback banner / approximate-location badge.
    final bottomReserve = 24.0;

    return Stack(
      children: [
        // Full Mapbox map — always rendered (even with zero pins the
        // map gives geographic context).
        MapboxMapWidget(
          markers: markers,
          centerLat: hasItems ? items.first.latitude! : defaultLat,
          centerLng: hasItems ? items.first.longitude! : defaultLng,
          zoom: 12,
          // Fit-to-markers stays the default when no bbox is supplied;
          // when a bbox is supplied, the underlying map widget prefers
          // the bbox path over fit-to-markers. With zero pins,
          // fit-to-markers is a no-op anyway.
          fitMarkers: bbox == null && hasItems,
          interactive: true,
          isDark: isDark,
          // PROD-2016: tooltip flow replaces the legacy
          // `onMarkerTap → showItemDetailSheet`. Shell handles
          // selection state; we provide the content + the navigation
          // callback.
          tooltipContentResolver: _resolveTooltipContent,
          onViewDetails: _handleViewDetails,
          // PROD-2016: analytics context — list-cover vs the /lists
          // hub map. Derived from `bbox`: only the hub passes a
          // city bbox.
          analyticsContext: bbox == null ? 'list_cover' : 'lists_hub',
          // PROD-1978: opt into source-layer clustering.
          cluster: true,
          // PROD-3830: facet teardrop pins. Full asset set + per-marker
          // `mapPinKey(primaryFacet:)` — pink `pin-default` until a payload
          // carries a facet, then category-accurate with no app release.
          categoryIcons: true,
          categoryIconAssets: kMapPinAssets,
          // Captions ON here (umbrella decision #2): the list maps are the
          // surfaces where naming each pin earns its space.
          showPinCaptions: true,
          // Default size curve — this is a full-width map, not a compact one.
          // PROD-2205-followup: chip gated behind a single flag
          // (kListMapsStaticByDefault = false today). Flipping the
          // flag re-enables the chip across every list-map consumer
          // (cover, `/lists` hub, zine item, detail blocks).
          staticByDefault: kListMapsStaticByDefault,
          // PROD-2017: fit-all + my-location floating buttons now live
          // inside MapboxMapWidget. The shell handles their visibility
          // gating against the static-toggle state and their wiring
          // (fit-token bump + user-location centering). Other surfaces
          // (zine-item-multi) get the same controls by opting in.
          showFitAllButton: hasItems,
          showMyLocationButton: true,
          // PROD-2042 Wave 2's shared banner, finally switched on here: this
          // surface used to render `LocationSharingBanner` +
          // `ApproximateLocationBadge` itself, with its own copy of the tap
          // handler and analytics mapper. Same look, same behaviour, one
          // implementation. `fullWidth` keeps the bar this surface has always
          // shown; `bottomReserve + 8` keeps its exact former offset.
          showLocationStatusBanners: true,
          locationBannerStyle: LocationBannerStyle.fullWidth,
          bannerInset: EdgeInsets.fromLTRB(12, 0, 12, bottomReserve + 8),
          boundsConfig: MapBoundsConfig(
            paddingTop: 60,
            paddingBottom: 40,
            paddingLeft: 50,
            paddingRight: 50,
            maxZoom: 16,
            north: shouldFitBbox ? bbox.north : null,
            south: shouldFitBbox ? bbox.south : null,
            east: shouldFitBbox ? bbox.east : null,
            west: shouldFitBbox ? bbox.west : null,
          ),
        ),
      ],
    );
  }
}
