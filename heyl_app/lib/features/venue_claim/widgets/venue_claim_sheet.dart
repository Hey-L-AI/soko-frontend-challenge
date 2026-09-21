import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/web_navigation.dart';
import '../../../core/services/storage_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_cta_button.dart';

/// Claim-start sheet. The authorization URL comes from the venue-bound endpoint
/// rather than the generic Instagram connection flow, preserving its claim
/// state through the OAuth callback.
class VenueClaimSheet extends ConsumerStatefulWidget {
  const VenueClaimSheet({
    super.key,
    required this.venueId,
    required this.venueName,
    this.businessReturnPath,
  });

  final String venueId;
  final String venueName;

  /// Where to return after the claim's Instagram OAuth round-trip. Pass it when
  /// the claim starts from the Business Connect portal so the owner lands back
  /// there (seeing the venue now "under approval") instead of on `/home` — the
  /// full-page OAuth reload wipes in-memory state, so it's persisted to
  /// SharedPreferences before the redirect (PROD-4040). Null for other claim
  /// entry points, which keep the venue-detail return.
  final String? businessReturnPath;

  @override
  ConsumerState<VenueClaimSheet> createState() => _VenueClaimSheetState();
}

class _VenueClaimSheetState extends ConsumerState<VenueClaimSheet> {
  bool _startingInstagram = false;

  Future<void> _startInstagramClaim() async {
    setState(() => _startingInstagram = true);
    try {
      await ref.read(authStateProvider.notifier).ensureFreshToken();
      final result = await ref
          .read(venueClaimApiProvider)
          .initiateInstagramClaim(widget.venueId);
      final storage = ref.read(storageServiceProvider);
      await storage.savePendingVenueClaimVenueId(widget.venueId);
      // Persist the portal return only now that a redirect is imminent, so a
      // failed start never leaves a stale return path behind.
      if (widget.businessReturnPath != null) {
        await storage.saveBusinessConnectReturnPath(widget.businessReturnPath!);
      }
      final url = Uri.parse(result.authorizationUrl);
      if (kIsWeb) {
        navigateViaForm(url.toString());
      } else {
        await launchUrl(
          url,
          mode: defaultTargetPlatform == TargetPlatform.android
              ? LaunchMode.inAppBrowserView
              : LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      if (!mounted) return;
      showSoko(
        ref,
        message: Lt.of(context).businessOwnershipClaimStartFailure,
        variant: SokoVariant.error,
      );
      setState(() => _startingInstagram = false);
    }
  }

  Future<void> _emailUs() async {
    final l10n = Lt.of(context);
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@soko.fyi',
      queryParameters: {
        'subject': l10n.businessOwnershipEmailSubject(widget.venueName),
      },
    );
    await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return DSSheetShell(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.businessOwnershipClaimTitle(widget.venueName),
              style: const TextStyle(
                fontFamily: 'UnJamoBatang',
                fontSize: 28,
                height: .96,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.businessOwnershipClaimDescription,
              style: const TextStyle(fontSize: 14, height: 1.35),
            ),
            const SizedBox(height: 20),
            SokoCtaButton(
              icon: LucideIcons.instagram,
              label: l10n.businessOwnershipVerifyInstagram,
              variant: SokoCtaVariant.lilac,
              loading: _startingInstagram,
              onPressed: _startInstagramClaim,
            ),
            const SizedBox(height: 20),
            Wrap(
              children: [
                Text(l10n.businessOwnershipNoInstagram),
                InkWell(
                  onTap: _emailUs,
                  child: Text(
                    l10n.businessOwnershipEmailUs,
                    style: const TextStyle(
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
