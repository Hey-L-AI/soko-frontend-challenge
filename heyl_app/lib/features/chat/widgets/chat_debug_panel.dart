import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/services/attribution_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/location_snapshot.dart';
import '../../../data/models/resolved_search_location.dart';
import '../../../data/models/session.dart';
import '../../../data/models/user_profile.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../providers/city_auto_scope_provider.dart';
import '../../../providers/city_scope_provider.dart';
import '../../../providers/locale_provider.dart';
import '../../../providers/location_provider.dart';
import '../../../providers/memory_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import '../../../providers/session_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/right_edge_tab_slots.dart';

/// Admin-only chat diagnostics. It intentionally separates client-observed
/// inputs from the backend's persisted session center, so a location drift is
/// visible instead of being hidden by a single friendly label.
final chatDebugPanelOpenProvider = StateProvider<bool>((ref) => false);

/// Distance between the persisted chat center and the current picker center.
/// Null means one side has not resolved, so no comparison is possible.
@visibleForTesting
double? chatSearchCenterDriftMeters({
  required SessionSearchCenter? sessionCenter,
  required ResolvedSearchLocation? currentCenter,
}) {
  if (sessionCenter == null || currentCenter?.hasCenter != true) return null;

  const earthRadiusMeters = 6371000.0;
  double radians(double value) => value * math.pi / 180;
  final dLat = radians(currentCenter!.centerLat! - sessionCenter.latitude);
  final dLon = radians(currentCenter.centerLon! - sessionCenter.longitude);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(radians(sessionCenter.latitude)) *
          math.cos(radians(currentCenter.centerLat!)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class ChatDebugTab extends ConsumerStatefulWidget {
  const ChatDebugTab({super.key});

  @override
  ConsumerState<ChatDebugTab> createState() => _ChatDebugTabState();
}

class _ChatDebugTabState extends ConsumerState<ChatDebugTab> {
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
    final open = ref.watch(chatDebugPanelOpenProvider);

    return Positioned(
      right: 0,
      top: rightEdgeTabSlotTop(context, _slot!),
      child: PointerInterceptor(
        child: Opacity(
          opacity: open ? 0.95 : 0.62,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () =>
                  ref.read(chatDebugPanelOpenProvider.notifier).state = !open,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                bottomLeft: Radius.circular(10),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 12,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.sokoLilac,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.message_circle, size: 14),
                    SizedBox(height: 6),
                    RotatedBox(
                      quarterTurns: 3,
                      child: Text(
                        'Chat',
                        style: TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
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

class ChatDebugPanel extends ConsumerWidget {
  const ChatDebugPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user?.role != UserRole.admin ||
        !ref.watch(chatDebugPanelOpenProvider)) {
      return const SizedBox.shrink();
    }

    final admin = user!;
    final sessionId = ref.watch(activeSessionIdProvider);
    final session = ref.watch(activeSessionProvider);
    final chat = sessionId == null ? null : ref.watch(chatProvider(sessionId));
    final location = ref.watch(locationProvider);
    final serverLocation = ref
        .watch(locationProvider.notifier)
        .lastBackendLocation;
    final currentCenter = ref.watch(resolvedSearchLocationProvider).valueOrNull;
    final seed = ref.watch(chatSeedLocationProvider);
    final autoScope = ref.watch(cityAutoScopeProvider).valueOrNull;
    final pickerScope = ref.watch(cityScopeProvider);
    final memory = ref.watch(memoryProvider);
    final locale = ref.watch(apiLocaleCodeProvider);
    final visitorId = ref.watch(attributionServiceProvider).cachedVisitorId;
    final drift = chatSearchCenterDriftMeters(
      sessionCenter: session?.searchCenter,
      currentCenter: currentCenter,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? const Color(0xFFE7DDD4) : AppColors.sokoInk;

    final report = _ChatDebugReport(
      user: admin,
      sessionId: sessionId,
      session: session,
      chat: chat,
      deviceLocation: location.lastLocation,
      serverLocation: serverLocation,
      currentCenter: currentCenter,
      seed: seed.valueOrNull,
      seedLoading: seed.isLoading,
      pickerScope: pickerScope?.runtimeType.toString(),
      autoScope: autoScope?.runtimeType.toString(),
      locale: locale,
      visitorId: visitorId,
      memoryCount: memory.totalCount,
      memoryLoading: memory.isLoading,
      memoryError: memory.error,
      driftMeters: drift,
    );

    final media = MediaQuery.of(context);
    return Positioned(
      right: 12,
      top: media.padding.top + 12,
      child: PointerInterceptor(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 380,
            maxHeight: media.size.height * 0.78,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1414) : AppColors.sokoPaper,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.sokoLilac.withValues(alpha: 0.8),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          LucideIcons.message_circle,
                          size: 13,
                          color: ink.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Chat debug',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: ink.withValues(alpha: 0.7),
                          ),
                        ),
                        const Spacer(),
                        _ChatDebugIconButton(
                          icon: LucideIcons.copy,
                          color: AppColors.sokoLilac,
                          onTap: () {
                            Clipboard.setData(
                              ClipboardData(text: report.toClipboard()),
                            );
                            showSokoFromContext(
                              context,
                              message: 'Chat debug copied',
                              variant: SokoVariant.info,
                              duration: const Duration(seconds: 2),
                            );
                          },
                        ),
                        const SizedBox(width: 2),
                        _ChatDebugIconButton(
                          icon: LucideIcons.x,
                          color: AppColors.sokoLilac,
                          onTap: () =>
                              ref
                                      .read(chatDebugPanelOpenProvider.notifier)
                                      .state =
                                  false,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _ChatDebugSection(
                      title: 'Session',
                      rows: [
                        _ChatDebugRow('id', report.sessionId ?? 'new chat'),
                        _ChatDebugRow('channel', session?.channel.name ?? '—'),
                        _ChatDebugRow(
                          'messages',
                          '${chat?.messages.length ?? 0} loaded / ${session?.totalMessages ?? '—'} persisted',
                        ),
                        _ChatDebugRow('runs', '${session?.totalRuns ?? '—'}'),
                        _ChatDebugRow(
                          'send',
                          chat == null ? 'idle' : _sendState(chat),
                        ),
                        if (chat?.error != null)
                          _ChatDebugRow('error', chat!.error!),
                      ],
                    ),
                    _ChatDebugSection(
                      title: 'Search Center, persisted by backend',
                      rows: [
                        _ChatDebugRow(
                          'label',
                          session?.searchCenter?.label ?? 'not returned',
                        ),
                        _ChatDebugRow(
                          'coordinates',
                          _sessionCoordinates(session?.searchCenter),
                        ),
                      ],
                    ),
                    _ChatDebugSection(
                      title: 'Search Center, current picker (C)',
                      rows: [
                        _ChatDebugRow(
                          'label',
                          currentCenter?.label ?? 'resolving / unavailable',
                        ),
                        _ChatDebugRow(
                          'coordinates',
                          _resolvedCoordinates(currentCenter),
                        ),
                        _ChatDebugRow(
                          'origin',
                          currentCenter == null
                              ? '—'
                              : '${currentCenter.origin.name} · ${currentCenter.isExplicit ? 'picked' : 'auto'}',
                        ),
                        _ChatDebugRow(
                          'radius',
                          currentCenter?.radiusMeters == null
                              ? '—'
                              : '${currentCenter!.radiusMeters!.round()} m',
                        ),
                        _ChatDebugRow(
                          'boundary',
                          currentCenter?.boundaryId ?? '—',
                        ),
                        _ChatDebugRow('drift vs session', _driftLabel(drift)),
                      ],
                    ),
                    _ChatDebugSection(
                      title: 'Outgoing message location (U)',
                      rows: [
                        _ChatDebugRow(
                          'outgoing',
                          _snapshot(location.lastLocation),
                        ),
                        _ChatDebugRow(
                          'server cache',
                          _snapshot(serverLocation),
                        ),
                        _ChatDebugRow(
                          'new-session seed',
                          seed.isLoading
                              ? 'resolving…'
                              : _snapshot(seed.valueOrNull),
                        ),
                      ],
                    ),
                    _ChatDebugSection(
                      title: 'Client context',
                      rows: [
                        _ChatDebugRow(
                          'user',
                          '${admin.id} · ${admin.role.name}',
                        ),
                        _ChatDebugRow('locale', locale ?? 'default'),
                        _ChatDebugRow(
                          'visitor id (text)',
                          report.visitorId ?? 'none',
                        ),
                        _ChatDebugRow(
                          'picker scope',
                          report.pickerScope ?? 'none',
                        ),
                        _ChatDebugRow(
                          'auto scope',
                          report.autoScope ?? 'unavailable',
                        ),
                        _ChatDebugRow(
                          'memory',
                          memory.isLoading
                              ? 'loading…'
                              : '${memory.totalCount} facts${memory.error == null ? '' : ' · error'}',
                        ),
                        _ChatDebugRow(
                          'translation',
                          memory.translationStatus.name,
                        ),
                      ],
                    ),
                    const _ChatDebugSection(
                      title: 'Backend execution context',
                      rows: [
                        _ChatDebugRow(
                          'status',
                          'Unavailable in the current API',
                        ),
                        _ChatDebugRow(
                          'tracking',
                          'PROD-3224, admin-only execution snapshot',
                        ),
                        _ChatDebugRow(
                          'meaning',
                          'Local inputs above are not proof of the backend decision.',
                        ),
                      ],
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

  static String _sendState(ChatState state) {
    if (state.isStreaming) return 'streaming';
    if (state.isSending) return 'sending';
    if (state.isLoading) return 'loading';
    return 'idle';
  }

  static String _sessionCoordinates(SessionSearchCenter? center) =>
      center == null
      ? 'not returned'
      : '${center.latitude.toStringAsFixed(5)}, ${center.longitude.toStringAsFixed(5)}';

  static String _resolvedCoordinates(ResolvedSearchLocation? center) =>
      center?.hasCenter != true
      ? '—'
      : '${center!.centerLat!.toStringAsFixed(5)}, ${center.centerLon!.toStringAsFixed(5)}';

  static String _snapshot(LocationSnapshot? snapshot) {
    if (snapshot == null) return 'none';
    final place = [
      snapshot.city,
      snapshot.country,
    ].whereType<String>().where((v) => v.isNotEmpty).join(', ');
    final name = place.isEmpty ? '' : '$place · ';
    final accuracy = snapshot.accuracyM == null
        ? ''
        : ' ±${snapshot.accuracyM!.round()}m';
    return '$name${snapshot.lat.toStringAsFixed(5)}, ${snapshot.lon.toStringAsFixed(5)} · ${snapshot.source.toJson()}$accuracy';
  }

  static String _driftLabel(double? meters) {
    if (meters == null) return 'not comparable';
    if (meters < 50) return '${meters.round()} m · aligned';
    if (meters < 1000) return '${meters.round()} m · differs';
    return '${(meters / 1000).toStringAsFixed(1)} km · differs';
  }
}

class _ChatDebugReport {
  const _ChatDebugReport({
    required this.user,
    required this.sessionId,
    required this.session,
    required this.chat,
    required this.deviceLocation,
    required this.serverLocation,
    required this.currentCenter,
    required this.seed,
    required this.seedLoading,
    required this.pickerScope,
    required this.autoScope,
    required this.locale,
    required this.visitorId,
    required this.memoryCount,
    required this.memoryLoading,
    required this.memoryError,
    required this.driftMeters,
  });

  final UserProfile user;
  final String? sessionId;
  final Session? session;
  final ChatState? chat;
  final LocationSnapshot? deviceLocation;
  final LocationSnapshot? serverLocation;
  final ResolvedSearchLocation? currentCenter;
  final LocationSnapshot? seed;
  final bool seedLoading;
  final String? pickerScope;
  final String? autoScope;
  final String? locale;
  final String? visitorId;
  final int memoryCount;
  final bool memoryLoading;
  final String? memoryError;
  final double? driftMeters;

  String toClipboard() => [
    'HeyL chat debug',
    'Session ID: ${sessionId ?? 'new chat'}',
    'Persisted C: ${ChatDebugPanel._sessionCoordinates(session?.searchCenter)} (${session?.searchCenter?.label ?? 'not returned'})',
    'Current C: ${ChatDebugPanel._resolvedCoordinates(currentCenter)} (${currentCenter?.label ?? 'unavailable'})',
    'C drift: ${ChatDebugPanel._driftLabel(driftMeters)}',
    'Outgoing U: ${ChatDebugPanel._snapshot(deviceLocation)}',
    'Server U: ${ChatDebugPanel._snapshot(serverLocation)}',
    'New-session seed: ${seedLoading ? 'resolving' : ChatDebugPanel._snapshot(seed)}',
    'Locale: ${locale ?? 'default'}',
    'Visitor ID (text): ${visitorId ?? 'none'}',
    'Memory: ${memoryLoading ? 'loading' : '$memoryCount facts'}${memoryError == null ? '' : ' (error)'}',
    'Backend execution context: unavailable, tracked in PROD-3224',
  ].join('\n');
}

class _ChatDebugSection extends StatelessWidget {
  final String title;
  final List<_ChatDebugRow> rows;

  const _ChatDebugSection({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.sokoLilac.withValues(alpha: 0.9),
          ),
        ),
        const SizedBox(height: 3),
        for (final row in rows) row,
      ],
    ),
  );
}

class _ChatDebugRow extends StatelessWidget {
  final String label;
  final String value;

  const _ChatDebugRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final keyColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final valueColor = isDark
        ? const Color(0xFFE7DDD4)
        : const Color(0xFF3A3232);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 102,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: keyColor,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11,
                color: valueColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatDebugIconButton extends StatelessWidget {
  const _ChatDebugIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
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
        child: Icon(icon, size: 13, color: color.withValues(alpha: 0.7)),
      ),
    ),
  );
}
