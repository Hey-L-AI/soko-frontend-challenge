import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:map_launcher/map_launcher.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/google_maps_url.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';

/// Open the venue in a native maps app on iOS/Android (with picker when
/// multiple installed) or in a new tab on the web. Returns the
/// destination_type label of the chosen provider (`'google_maps'`,
/// `'apple_maps'`, `'other_maps'`) so callers can attribute analytics
/// correctly, or `null` if no map ended up launching.
///
/// Forked from the legacy item detail sheet during the venue-page rebuild;
/// the source has since been retired (PROD-1672).
Future<String?> openVenueInMaps(
  BuildContext context, {
  required VenueDetailResponse venue,
}) async {
  if (kIsWeb) {
    await _openMapsViaUrl(venue);
    return 'google_maps';
  }

  final available = await MapLauncher.installedMaps;
  if (available.isEmpty) {
    await _openMapsViaUrl(venue);
    return 'google_maps';
  }
  if (available.length == 1) {
    return _launchMap(available.first, venue);
  }
  if (!context.mounted) return null;
  return _showPicker(context, available, venue);
}

Future<String?> _showPicker(
  BuildContext context,
  List<AvailableMap> maps,
  VenueDetailResponse venue,
) async {
  final l10n = Lt.of(context);
  final picked = await showModalBottomSheet<AvailableMap>(
    context: context,
    backgroundColor: AppColors.sokoPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l10n.mapPickerTitle,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontWeight: FontWeight.w500,
                fontSize: 16,
                color: AppColors.sokoInk,
              ),
            ),
          ),
          const Divider(height: 1),
          ...maps.map(
            (m) => ListTile(
              leading: SvgPicture.asset(m.icon, height: 28, width: 28),
              title: Text(m.mapName),
              onTap: () => Navigator.pop(ctx, m),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (picked == null) return null;
  return _launchMap(picked, venue);
}

Future<String> _launchMap(AvailableMap map, VenueDetailResponse venue) async {
  // Prefer URL-based opening for Google + Apple Maps so the user lands on
  // the place page (with reviews/photos), not a raw pin drop. PROD-696.
  if (map.mapType == MapType.google &&
      (venue.googleMapsUrl != null || venue.name.isNotEmpty)) {
    await _openMapsViaUrl(venue);
    return 'google_maps';
  }
  if (map.mapType == MapType.apple && venue.name.isNotEmpty) {
    await _openAppleMaps(venue);
    return 'apple_maps';
  }

  // Other apps (Waze, etc.) — fall back to native showMarker.
  if (venue.latitude != null && venue.longitude != null) {
    await map.showMarker(
      coords: Coords(venue.latitude!, venue.longitude!),
      title: venue.name,
    );
    return _providerLabel(map.mapType);
  } else {
    await _openMapsViaUrl(venue);
    return 'google_maps';
  }
}

String _providerLabel(MapType type) {
  switch (type) {
    case MapType.google:
      return 'google_maps';
    case MapType.apple:
      return 'apple_maps';
    default:
      return 'other_maps';
  }
}

Future<void> _openAppleMaps(VenueDetailResponse venue) async {
  final query = _buildSearchQuery(venue);
  final uri = Uri.parse(
    'https://maps.apple.com/?q=${Uri.encodeComponent(query)}',
  );
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (e) {
    debugPrint('Error launching Apple Maps URL: $e');
  }
}

Future<void> _openMapsViaUrl(VenueDetailResponse venue) async {
  // PROD-1673: prefer the canonical `query_place_id` URL when we have a
  // place_id. The BE-emitted `venue.googleMapsUrl` uses the older
  // `q=place_id:<ID>` syntax which works in browsers but the native Google
  // Maps app on iOS/Android dumps the literal `place_id:<ID>` into its
  // search bar. Fall back to the BE URL only when no place_id is present.
  String? url = GoogleMapsUrl.canonicalPlaceUrl(
    placeId: venue.googlePlaceId,
    name: venue.name,
    latitude: venue.latitude,
    longitude: venue.longitude,
  );
  url ??= venue.googleMapsUrl;
  if (url == null) {
    final query = _buildSearchQuery(venue);
    url =
        'https://www.google.com/maps/search/?api=1&query='
        '${Uri.encodeComponent(query)}';
  }
  final uri = Uri.parse(url);
  try {
    if (kIsWeb) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    } else if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (e) {
    debugPrint('Error launching maps URL: $e');
  }
}

String _buildSearchQuery(VenueDetailResponse venue) {
  final parts = <String>[venue.name];
  if (venue.address != null) parts.add(venue.address!);
  if (venue.city != null && (venue.address?.contains(venue.city!) != true)) {
    parts.add(venue.city!);
  }
  return parts.join(', ');
}
