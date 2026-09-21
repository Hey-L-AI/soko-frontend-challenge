import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../core/theme/app_colors.dart';
import '../providers/shell_stray_tap_provider.dart';
import 'right_edge_tab_slots.dart';
import '../../data/models/location_snapshot.dart';
import '../../data/models/resolved_search_location.dart';
import '../../data/models/user_profile.dart';
import '../../features/lists/models/search_scope.dart';
import '../../l10n/generated/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/city_auto_scope_provider.dart';
import '../../providers/city_scope_provider.dart';
import '../../providers/location_provider.dart';
import '../../providers/resolved_search_location_provider.dart';
import '../utils/search_range.dart';
import '../notifications/heyl_notification.dart';
import '../notifications/notification_state.dart';

/// Admin-only diagnostics that surface the app's several distinct "location"
/// values side by side so drift between them is visible at a glance:
///
/// - **GPS** — the live device fix ([LocationState.lastLocation]).
/// - **User loc** — what the app believes the server has
///   ([LocationNotifier.lastBackendLocation]); the coordinate the AI resolves
///   "near me" against for authenticated users.
/// - **Outgoing U** — the live device fix attached to every outgoing chat
///   message for both authenticated people and guests.
/// - **Search · disc** — the Discovery picker's resolved city + centroid, and
///   whether it was auto-detected or explicitly picked.
///
/// Surfaced two ways: a right-edge [LocationDebugTab] that toggles the docked
/// [LocationDebugPanel] (chat + discovery, mounted in the shell), and as a
/// section inside the Map page's debug panel via [AdminLocationDebugContent].

/// Whether the docked location-debug panel is open. Toggled by
/// [LocationDebugTab], read by [LocationDebugPanel]. Mirrors
/// `mapDebugPanelOpenProvider`.
final locationDebugPanelOpenProvider = StateProvider<bool>((ref) => false);

/// Builds the current [_AdminLocationData] snapshot from the location + picker
/// providers. Watching the location state drives rebuilds; `lastBackendLocation`
/// lives outside `LocationState` on the notifier and refreshes on those emits.
_AdminLocationData _buildData(WidgetRef ref) {
  final locState = ref.watch(locationProvider);
  final gps = locState.lastLocation;
  final serverLoc = ref.watch(locationProvider.notifier).lastBackendLocation;
  final resolved = ref.watch(resolvedSearchLocationProvider).valueOrNull;
  // Discovery's live requests still derive their coordinates from this scope
  // directly (see `_resolveDiscoveryGeo`). Read the same value here so this
  // panel reports the actual search input, rather than a possibly older value
  // held by the asynchronous display resolver.
  final explicitScope = ref.watch(cityScopeProvider);
  final autoScope = ref.watch(cityAutoScopeProvider).valueOrNull;
  final discoveryScope = explicitScope ?? autoScope;

  // Outgoing chat messages always attach the latest device U. The persisted
  // session C is intentionally shown only in ChatDebugPanel, where it can be
  // distinguished from this request context without a misleading label.
  final chatSnap = gps;
  const chatTag = 'all users · device';

  return _AdminLocationData(
    gps: gps,
    serverLoc: serverLoc,
    chatSnap: chatSnap,
    chatTag: chatTag,
    discoveryScope: discoveryScope,
    resolved: resolved,
    // Backend-resolved place from the last location roundtrip. Prefers the
    // finer neighbourhood/parish over the city (both come from the server's
    // canonical admin-boundary reverse geocode — see location_provider).
    resolvedNeighborhood: locState.resolvedNeighborhood,
    resolvedCity: locState.resolvedCityName,
    resolvedCountry: locState.resolvedCountryCode,
  );
}

/// The reusable body of the location-debug panel: an optional header (title +
/// copy + close) followed by the four location rows. Used both inside the
/// docked [LocationDebugPanel] (chat/discovery) and as a section in the Map
/// page's debug panel. Does NOT gate on admin — callers own the gate.
class AdminLocationDebugContent extends ConsumerWidget {
  /// When set, renders a header row (pin icon + this title + copy button, and
  /// the close button if [onClose] is provided). When null, renders rows only.
  final String? title;

  /// Optional close affordance rendered in the header (docked panel only).
  final VoidCallback? onClose;

  const AdminLocationDebugContent({super.key, this.title, this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = _buildData(ref);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final labelColor =
        (isDark ? AppColors.textSecondaryDark : AppColors.textSecondary)
            .withValues(alpha: 0.7);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Row(
            children: [
              Icon(LucideIcons.map_pin, size: 13, color: labelColor),
              const SizedBox(width: 8),
              Text(
                title!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
              ),
              const Spacer(),
              _CopyButton(
                clipboardText: data.toClipboard(),
                color: primaryColor,
              ),
              if (onClose != null) ...[
                const SizedBox(width: 2),
                _IconButton(
                  icon: LucideIcons.x,
                  color: primaryColor,
                  onTap: onClose!,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
        ],
        for (final line in data.lines()) _Row(line: line, isDark: isDark),
      ],
    );
  }
}

/// Right-edge, admin-only tab that toggles the docked [LocationDebugPanel].
/// Mirrors `FeedbackSideTab` / `MapDebugTab`. Returns a [Positioned] — add it
/// directly to a shell/page body `Stack`. Self-gates: renders nothing for
/// non-admins.
///
/// Positioned via [RightEdgeTabSlots] (PROD-3124): the Feedback tab keeps its
/// fixed 40% anchor; this tab claims the first free slot below it — so it and
/// the Map page's Debug tab (mounted from a different Stack) stack instead of
/// overlapping (they used to hard-code the same `0.4h + 140` spot). The slot
/// is claimed only while actually rendering, so a non-admin's invisible tab
/// never holds a gap open.
class LocationDebugTab extends ConsumerStatefulWidget {
  const LocationDebugTab({super.key});

  @override
  ConsumerState<LocationDebugTab> createState() => _LocationDebugTabState();
}

class _LocationDebugTabState extends ConsumerState<LocationDebugTab> {
  int? _slot;

  @override
  void dispose() {
    RightEdgeTabSlots.release(_slot);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    if (user?.role != UserRole.admin) {
      RightEdgeTabSlots.release(_slot);
      _slot = null;
      return const SizedBox.shrink();
    }
    _slot ??= RightEdgeTabSlots.claim();

    final open = ref.watch(locationDebugPanelOpenProvider);

    return Positioned(
      right: 0,
      top: rightEdgeTabSlotTop(context, _slot!),
      child: PointerInterceptor(
        child: Opacity(
          opacity: open ? 0.95 : 0.62,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                // PROD-3627 — same stray-tap rule as the feedback tab: this
                // floats above every page's chrome, so a page-local overlay
                // cannot scrim it. Dismiss-only on the first tap.
                final dismiss = ref.read(shellStrayTapDismissProvider);
                if (dismiss != null && dismiss()) return;
                ref.read(locationDebugPanelOpenProvider.notifier).state = !open;
              },
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                bottomLeft: Radius.circular(10),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppColors.sokoYellow,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.sokoInk.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(-2, 0),
                    ),
                  ],
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.map_pin,
                      size: 14,
                      color: AppColors.sokoInk,
                    ),
                    SizedBox(height: 6),
                    RotatedBox(
                      quarterTurns: 3,
                      child: Text(
                        'Loc',
                        style: TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                          color: AppColors.sokoInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The docked (non-modal) location-debug card, toggled by [LocationDebugTab].
/// Top-left overlay so the surface underneath stays interactive. Renders only
/// when the toggle is on AND the current user is an admin. Returns a
/// [Positioned] — add it to the shell/page body `Stack` next to the tab.
class LocationDebugPanel extends ConsumerWidget {
  const LocationDebugPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user?.role != UserRole.admin) return const SizedBox.shrink();
    if (!ref.watch(locationDebugPanelOpenProvider)) {
      return const SizedBox.shrink();
    }

    final media = MediaQuery.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    return Positioned(
      left: 12,
      top: media.padding.top + 12,
      child: PointerInterceptor(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 360,
            maxHeight: media.size.height * 0.7,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1414) : AppColors.sokoPaper,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: primaryColor.withValues(alpha: 0.6),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.sokoInk.withValues(alpha: 0.2),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: AdminLocationDebugContent(
                  title: 'Location debug',
                  onClose: () =>
                      ref.read(locationDebugPanelOpenProvider.notifier).state =
                          false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Rendering
// ============================================================================

class _Row extends StatelessWidget {
  final _LocLine line;
  final bool isDark;

  const _Row({required this.line, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final keyColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final valueColor = isDark
        ? const Color(0xFFE7DDD4)
        : const Color(0xFF3A3232);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: line.status.color,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 74,
            child: Text(
              line.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: keyColor,
              ),
            ),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  color: valueColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                children: [
                  TextSpan(text: line.value),
                  if (line.meta != null)
                    TextSpan(
                      text: '  ${line.meta}',
                      style: TextStyle(
                        color: valueColor.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final String clipboardText;
  final Color color;

  const _CopyButton({required this.clipboardText, required this.color});

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: clipboardText));
    showSokoFromContext(
      context,
      message: Lt.of(context).adminCopiedToClipboard,
      variant: SokoVariant.info,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _IconButton(
      icon: LucideIcons.copy,
      color: color,
      onTap: () => _copy(context),
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _IconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 13, color: color.withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}

// ============================================================================
// Data model + formatting
// ============================================================================

enum _Status {
  ok(Color(0xFF3BA776)),
  warn(Color(0xFFD9A441)),
  alert(Color(0xFFC76274)),
  unknown(Color(0xFF9A9A9A));

  const _Status(this.color);
  final Color color;
}

class _LocLine {
  final String label;
  final String value;
  final String? meta;
  final _Status status;

  const _LocLine(this.label, this.value, this.meta, this.status);
}

class _AdminLocationData {
  final LocationSnapshot? gps;
  final LocationSnapshot? serverLoc;
  final LocationSnapshot? chatSnap;
  final String chatTag;
  final SearchScope? discoveryScope;
  final ResolvedSearchLocation? resolved;
  final String? resolvedNeighborhood;
  final String? resolvedCity;
  final String? resolvedCountry;

  const _AdminLocationData({
    required this.gps,
    required this.serverLoc,
    required this.chatSnap,
    required this.chatTag,
    required this.discoveryScope,
    required this.resolved,
    required this.resolvedNeighborhood,
    required this.resolvedCity,
    required this.resolvedCountry,
  });

  /// Human-readable place for a snapshot. Prefers the snapshot's own city
  /// (present on IP-approx fixes); otherwise, for the user's own location rows,
  /// uses the backend-resolved **neighbourhood → city** (both from the server's
  /// canonical admin-boundary reverse geocode). Returns null for arbitrary
  /// coords with no resolved name.
  String? _place(LocationSnapshot? s, {required bool userLoc}) {
    if (s?.city != null && s!.city!.isNotEmpty) {
      final c = s.country;
      return c != null && c.isNotEmpty ? '${s.city}, $c' : s.city;
    }
    if (userLoc) {
      final hood = resolvedNeighborhood;
      final city = resolvedCity;
      if (hood != null && hood.isNotEmpty) {
        return city != null && city.isNotEmpty ? '$hood, $city' : hood;
      }
      if (city != null && city.isNotEmpty) {
        final c = resolvedCountry;
        return c != null && c.isNotEmpty ? '$city, $c' : city;
      }
    }
    return null;
  }

  List<_LocLine> lines() => [
    _gpsLine(),
    _serverLine(),
    _chatLine(),
    _discoveryLine(),
  ];

  _LocLine _gpsLine() {
    if (gps == null) {
      return const _LocLine('GPS', 'none', null, _Status.alert);
    }
    final approx =
        gps!.source.isImpreciseSource ||
        (gps!.accuracyM != null && gps!.accuracyM! > 500);
    final place = _place(gps, userLoc: true);
    return _LocLine(
      'GPS',
      place ?? _coords(gps!),
      '· ${place != null ? '${_coords(gps!)} · ' : ''}'
          '${_acc(gps!)} · ${_src(gps!.source)} · ${_age(gps!.capturedAt)}',
      // PROD-4486: an imprecise source (IP / inferred memory_fact / backend-only
      // / unknown) is never a real fix — alert, not just warn.
      gps!.source.isImpreciseSource
          ? _Status.alert
          : (approx ? _Status.warn : _Status.ok),
    );
  }

  _LocLine _serverLine() {
    if (serverLoc == null) {
      return _LocLine(
        'User loc',
        'none',
        gps != null ? '· server has no fix yet' : null,
        gps != null ? _Status.alert : _Status.unknown,
      );
    }
    final delta = gps == null ? null : _distanceM(gps!, serverLoc!);
    final place = _place(serverLoc, userLoc: true);
    final meta = StringBuffer('· ');
    if (place != null) meta.write('${_coords(serverLoc!)} · ');
    meta.write('${_src(serverLoc!.source)} · ${_age(serverLoc!.capturedAt)}');
    if (delta != null) meta.write(' · Δ${_dist(delta)}');
    _Status status;
    if (delta == null) {
      status = _Status.unknown;
    } else if (delta > 1000) {
      status = _Status.alert;
    } else if (delta > 150) {
      status = _Status.warn;
    } else {
      status = _Status.ok;
    }
    return _LocLine(
      'User loc',
      place ?? _coords(serverLoc!),
      meta.toString(),
      status,
    );
  }

  _LocLine _chatLine() {
    if (chatSnap == null) {
      return _LocLine('Outgoing U', 'none', '· $chatTag', _Status.alert);
    }
    final place = _place(chatSnap, userLoc: true);
    final meta = StringBuffer('· ');
    if (place != null) meta.write('${_coords(chatSnap!)} · ');
    meta.write(chatTag);
    return _LocLine(
      'Outgoing U',
      place ?? _coords(chatSnap!),
      meta.toString(),
      _Status.ok,
    );
  }

  _LocLine _discoveryLine() {
    // The Discovery search request reads its scope directly. This MUST stay in
    // lockstep with `_resolveDiscoveryGeo`, otherwise a picked neighbourhood
    // can be searched while this panel misleadingly reports the auto city.
    final scope = discoveryScope;
    if (scope != null) {
      final details = _discoveryScopeDetails(scope);
      final ref = gps ?? serverLoc;
      final delta = details.lat == null || ref == null
          ? null
          : _distanceMLatLon(ref.lat, ref.lon, details.lat!, details.lon!);
      final meta = StringBuffer('· ');
      if (details.lat != null) {
        meta.write(
          '${details.lat!.toStringAsFixed(3)}, '
          '${details.lon!.toStringAsFixed(3)} · ',
        );
      }
      meta.write(
        '${details.origin} · ${details.isExplicit ? 'picked' : 'auto'}',
      );
      if (details.radiusMeters != null) {
        meta.write(
          ' · r${(details.radiusMeters! / 1000).toStringAsFixed(1)}km',
        );
      }
      if (delta != null) meta.write(' · Δ${_dist(delta)}');
      return _LocLine(
        'Search·disc',
        details.label,
        meta.toString(),
        delta == null ? _Status.unknown : _Status.ok,
      );
    }

    // The resolver is still useful as a loading fallback when no request scope
    // has settled at all.
    final r = resolved;
    if (r == null || r.origin == ResolvedLocationOrigin.defaultLocation) {
      return const _LocLine(
        'Search·disc',
        'none',
        '· no picker scope',
        _Status.unknown,
      );
    }

    final tag = r.isExplicit ? 'picked' : 'auto';
    final hasCoords = r.hasCenter;
    final ref = gps ?? serverLoc;
    double? delta;
    if (hasCoords && ref != null) {
      delta = _distanceMLatLon(ref.lat, ref.lon, r.centerLat!, r.centerLon!);
    }
    final meta = StringBuffer('· ');
    if (hasCoords) {
      meta.write(
        '${r.centerLat!.toStringAsFixed(3)}, '
        '${r.centerLon!.toStringAsFixed(3)} · ',
      );
    }
    meta.write('${r.origin.name} · $tag');
    if (r.radiusMeters != null) {
      meta.write(' · r${(r.radiusMeters! / 1000).toStringAsFixed(1)}km');
    }
    if (r.cityId != null) meta.write(' · cid✓');
    if (delta != null) meta.write(' · Δ${_dist(delta)}');
    _Status status;
    if (delta == null) {
      status = _Status.unknown;
    } else if (delta > 25000) {
      status = _Status.warn;
    } else {
      status = _Status.ok;
    }
    final label = r.label ?? r.cityName ?? 'none';
    return _LocLine('Search·disc', label, meta.toString(), status);
  }

  String toClipboard() {
    String snap(String label, LocationSnapshot? s) {
      if (s == null) return '$label: none';
      final acc = s.accuracyM != null ? ' ±${s.accuracyM!.round()}m' : '';
      final place = _place(s, userLoc: true);
      final name = place != null ? '$place — ' : '';
      return '$label: $name${s.lat}, ${s.lon}$acc '
          '(${_src(s.source)}, ${s.capturedAt.toUtc().toIso8601String()})';
    }

    final lines = <String>[
      'HeyL location debug',
      snap('GPS (device fix)', gps),
      snap('User loc (server)', serverLoc),
      snap('Outgoing U ($chatTag)', chatSnap),
      if (resolved != null &&
          resolved!.origin != ResolvedLocationOrigin.defaultLocation)
        'Search·disc: ${resolved!.label ?? resolved!.cityName ?? 'none'} '
            '(${resolved!.centerLat}, ${resolved!.centerLon}) '
            'r=${resolved!.radiusMeters}m '
            'cityId=${resolved!.cityId ?? '-'} '
            '[${resolved!.origin.name} · ${resolved!.isExplicit ? 'picked' : 'auto'}]'
      else if (discoveryScope != null)
        'Search·disc: ${_discoveryScopeDetails(discoveryScope!).label}'
      else
        'Search·disc: none',
      'Captured at: ${DateTime.now().toUtc().toIso8601String()}',
    ];
    return lines.join('\n');
  }
}

/// The hierarchy shown for Discovery must be the hierarchy sent in its active
/// scope, not a city-only projection of that scope.
@visibleForTesting
String discoverySearchScopeDebugLabel(SearchScope scope) =>
    _discoveryScopeDetails(scope).label;

({
  String label,
  double? lat,
  double? lon,
  double? radiusMeters,
  String origin,
  bool isExplicit,
})
_discoveryScopeDetails(SearchScope scope) => switch (scope) {
  SearchScopeArea(
    :final displayName,
    :final centerLat,
    :final centerLng,
    :final radiusMeters,
    :final isAuto,
  ) =>
    (
      label: displayName.isEmpty ? 'Unnamed area' : displayName,
      lat: centerLat,
      lon: centerLng,
      radiusMeters: radiusMeters,
      origin: 'area',
      isExplicit: !isAuto,
    ),
  SearchScopeCountryCity(:final city, :final iso2, :final isAuto) => (
    label: city.displayName.isEmpty ? '${city.name}, $iso2' : city.displayName,
    lat: city.latitude,
    lon: city.longitude,
    radiusMeters: SearchRange.city.radiusMeters,
    origin: 'city',
    isExplicit: !isAuto,
  ),
  SearchScopeCountry(:final countryName, :final isAuto) => (
    label: countryName,
    lat: null,
    lon: null,
    radiusMeters: null,
    origin: 'country',
    isExplicit: !isAuto,
  ),
};

// ---- formatting helpers ----

String _coords(LocationSnapshot s) =>
    '${s.lat.toStringAsFixed(5)}, ${s.lon.toStringAsFixed(5)}';

String _acc(LocationSnapshot s) =>
    s.accuracyM != null ? '±${s.accuracyM!.round()}m' : '±?';

String _src(LocationSource src) => switch (src) {
  LocationSource.deviceGps => 'gps',
  LocationSource.deviceNetwork => 'net',
  LocationSource.manualMapPin => 'pin',
  LocationSource.ipApprox => 'ip',
  LocationSource.memoryFact => 'mem',
  LocationSource.migration => 'mig',
  LocationSource.whatsapp => 'wa',
  LocationSource.unknown => 'unk',
};

String _dist(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(1)}km'
    : '${meters.round()}m';

String _age(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

double _distanceM(LocationSnapshot a, LocationSnapshot b) =>
    _distanceMLatLon(a.lat, a.lon, b.lat, b.lon);

/// Haversine distance in metres.
double _distanceMLatLon(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _rad(double deg) => deg * math.pi / 180.0;
