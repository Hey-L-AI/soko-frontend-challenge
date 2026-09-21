import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:map_launcher/map_launcher.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';

/// Open the event's venue location in a native maps app on iOS/Android
/// (with picker when multiple installed) or in a new tab on the web.
/// Returns the destination_type label of the chosen provider so callers can
/// attribute analytics correctly (`'google_maps'`, `'apple_maps'`,
/// `'other_maps'`, or `null` if no map ended up launching).
///
/// Forked from `venue_detail/utils/maps_launcher.dart` so the event page
/// owns its own helper (cleaner than over-generalising the venue helper).
Future<String?> openEventInMaps(
  BuildContext context, {
  required EventDetailResponse2 event,
}) async {
  if (kIsWeb) {
    await _openMapsViaUrl(event);
    return 'google_maps';
  }

  final available = await MapLauncher.installedMaps;
  if (available.isEmpty) {
    await _openMapsViaUrl(event);
    return 'google_maps';
  }
  if (available.length == 1) {
    return _launchMap(available.first, event);
  }
  if (!context.mounted) return null;
  return _showPicker(context, available, event);
}

Future<String?> _showPicker(
  BuildContext context,
  List<AvailableMap> maps,
  EventDetailResponse2 event,
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
  return _launchMap(picked, event);
}

Future<String> _launchMap(AvailableMap map, EventDetailResponse2 event) async {
  // Prefer URL-based opening for Google + Apple Maps so the user lands on
  // the place page (with reviews/photos), not a raw pin drop.
  final hasName = (event.venueName ?? '').isNotEmpty || event.title.isNotEmpty;
  if (map.mapType == MapType.google && hasName) {
    await _openMapsViaUrl(event);
    return 'google_maps';
  }
  if (map.mapType == MapType.apple && hasName) {
    await _openAppleMaps(event);
    return 'apple_maps';
  }

  // Other apps (Waze, etc.) — fall back to native showMarker.
  if (event.latitude != null && event.longitude != null) {
    await map.showMarker(
      coords: Coords(event.latitude!, event.longitude!),
      title: event.venueName ?? event.title,
    );
    return _providerLabel(map.mapType);
  } else {
    await _openMapsViaUrl(event);
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

Future<void> _openAppleMaps(EventDetailResponse2 event) async {
  final query = _buildSearchQuery(event);
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

Future<void> _openMapsViaUrl(EventDetailResponse2 event) async {
  final query = _buildSearchQuery(event);
  final url =
      'https://www.google.com/maps/search/?api=1&query='
      '${Uri.encodeComponent(query)}';
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

String _buildSearchQuery(EventDetailResponse2 event) {
  final parts = <String>[];
  if ((event.venueName ?? '').isNotEmpty) {
    parts.add(event.venueName!);
  } else {
    parts.add(event.title);
  }
  if ((event.venueAddress ?? '').isNotEmpty) parts.add(event.venueAddress!);
  if ((event.venueCity ?? '').isNotEmpty &&
      (event.venueAddress?.contains(event.venueCity!) != true)) {
    parts.add(event.venueCity!);
  }
  return parts.join(', ');
}
