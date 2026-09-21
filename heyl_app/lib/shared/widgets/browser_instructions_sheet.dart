import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/location_service.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/generated/l10n.dart';
import '../../providers/location_provider.dart';
import '../utils/bottom_sheet_utils.dart';
import 'bottom_sheet/ds_sheet_shell.dart';

/// Data class for browser instruction cards
class _BrowserInstructionData {
  final String Function(Lt) getTitle;
  final List<String Function(Lt)> getSteps;
  final IconData icon;
  final Color iconColor;

  /// Optional "Still not working?" section with alternative steps
  final String Function(Lt)? getAltTitle;
  final List<String Function(Lt)>? getAltSteps;

  const _BrowserInstructionData({
    required this.getTitle,
    required this.getSteps,
    required this.icon,
    required this.iconColor,
    this.getAltTitle,
    this.getAltSteps,
  });
}

/// Modal bottom sheet showing browser-specific instructions for enabling location
/// Used on web platform when users have denied location permission
class BrowserInstructionsSheet extends StatelessWidget {
  final VoidCallback onCheckAgain;

  const BrowserInstructionsSheet({super.key, required this.onCheckAgain});

  /// Get the list of browser instructions ordered by platform relevance
  List<_BrowserInstructionData> _getBrowserInstructions() {
    // Define all browser instruction data
    final chromeDesktop = _BrowserInstructionData(
      getTitle: (l10n) => l10n.locationChromeDesktopTitle,
      getSteps: [
        (l10n) => l10n.locationChromeDesktopStep1,
        (l10n) => l10n.locationChromeDesktopStep2,
        (l10n) => l10n.locationChromeDesktopStep3,
        (l10n) => l10n.locationChromeDesktopStep4,
      ],
      icon: Icons.public,
      iconColor: const Color(0xFF4285F4), // Chrome blue
    );

    final chromeAndroid = _BrowserInstructionData(
      getTitle: (l10n) => l10n.locationChromeAndroidTitle,
      getSteps: [
        (l10n) => l10n.locationChromeAndroidStep1,
        (l10n) => l10n.locationChromeAndroidStep2,
        (l10n) => l10n.locationChromeAndroidStep3,
        (l10n) => l10n.locationChromeAndroidStep4,
      ],
      icon: Icons.phone_android,
      iconColor: const Color(0xFF4285F4), // Chrome blue
    );

    final safariMac = _BrowserInstructionData(
      getTitle: (l10n) => l10n.locationSafariMacTitle,
      getSteps: [
        (l10n) => l10n.locationSafariMacStep1,
        (l10n) => l10n.locationSafariMacStep2,
        (l10n) => l10n.locationSafariMacStep3,
        (l10n) => l10n.locationSafariMacStep4,
      ],
      icon: Icons.compass_calibration,
      iconColor: const Color(0xFF0066CC), // Safari blue
    );

    final safariIOS = _BrowserInstructionData(
      getTitle: (l10n) => l10n.locationSafariIOSTitle,
      getSteps: [
        (l10n) => l10n.locationSafariIOSStep1,
        (l10n) => l10n.locationSafariIOSStep2,
        (l10n) => l10n.locationSafariIOSStep3,
      ],
      icon: Icons.phone_iphone,
      iconColor: const Color(0xFF0066CC), // Safari blue
      getAltTitle: (l10n) => l10n.locationSafariIOSStillNotWorking,
      getAltSteps: [
        (l10n) => l10n.locationSafariIOSAltStep1,
        (l10n) => l10n.locationSafariIOSAltStep2,
        (l10n) => l10n.locationSafariIOSAltStep3,
      ],
    );

    final firefox = _BrowserInstructionData(
      getTitle: (l10n) => l10n.locationFirefoxTitle,
      getSteps: [
        (l10n) => l10n.locationFirefoxStep1,
        (l10n) => l10n.locationFirefoxStep2,
        (l10n) => l10n.locationFirefoxStep3,
        (l10n) => l10n.locationFirefoxStep4,
      ],
      icon: Icons.local_fire_department,
      iconColor: const Color(0xFFFF7139), // Firefox orange
    );

    // Order browsers by platform relevance
    final platform = defaultTargetPlatform;

    switch (platform) {
      case TargetPlatform.iOS:
        // iOS: Safari iOS first, then Chrome Android (in case using Chrome on iOS)
        return [safariIOS, chromeAndroid, safariMac, chromeDesktop, firefox];

      case TargetPlatform.android:
        // Android: Chrome Android first, then Firefox
        return [chromeAndroid, firefox, chromeDesktop, safariMac, safariIOS];

      case TargetPlatform.macOS:
        // macOS: Safari Mac first, then Chrome Desktop, then Firefox
        return [safariMac, chromeDesktop, firefox, safariIOS, chromeAndroid];

      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
      default:
        // Windows/Linux/Other: Chrome Desktop first, then Firefox
        return [chromeDesktop, firefox, safariMac, chromeAndroid, safariIOS];
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimaryColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final cardColor = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : AppColors.muted.withValues(alpha: 0.3);

    final browsers = _getBrowserInstructions();

    return DSSheetShell(
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Text(
              l10n.locationBrowserInstructionsTitle,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: textPrimaryColor,
              ),
            ),
            const SizedBox(height: 8),

            // Subtitle
            Text(
              l10n.locationBrowserInstructionsSubtitle,
              style: TextStyle(fontSize: 15, color: textSecondaryColor),
            ),
            const SizedBox(height: 24),

            // Browser instruction cards
            ...browsers.asMap().entries.map((entry) {
              final index = entry.key;
              final browser = entry.value;
              return Column(
                children: [
                  _BrowserInstructionCard(
                    browserName: browser.getTitle(l10n),
                    icon: browser.icon,
                    iconColor: browser.iconColor,
                    steps: browser.getSteps
                        .map((getStep) => getStep(l10n))
                        .toList(),
                    altTitle: browser.getAltTitle?.call(l10n),
                    altSteps: browser.getAltSteps
                        ?.map((getStep) => getStep(l10n))
                        .toList(),
                    cardColor: cardColor,
                    textPrimaryColor: textPrimaryColor,
                    textSecondaryColor: textSecondaryColor,
                    initiallyExpanded:
                        index == 0, // First card expanded by default
                  ),
                  if (index < browsers.length - 1) const SizedBox(height: 16),
                ],
              );
            }),

            const SizedBox(height: 32),

            // CTA Button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: onCheckAgain,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  l10n.locationIveEnabledIt,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Card showing instructions for a specific browser
class _BrowserInstructionCard extends StatefulWidget {
  final String browserName;
  final IconData icon;
  final Color iconColor;
  final List<String> steps;
  final String? altTitle;
  final List<String>? altSteps;
  final Color cardColor;
  final Color textPrimaryColor;
  final Color textSecondaryColor;
  final bool initiallyExpanded;

  const _BrowserInstructionCard({
    required this.browserName,
    required this.icon,
    required this.iconColor,
    required this.steps,
    this.altTitle,
    this.altSteps,
    required this.cardColor,
    required this.textPrimaryColor,
    required this.textSecondaryColor,
    this.initiallyExpanded = false,
  });

  @override
  State<_BrowserInstructionCard> createState() =>
      _BrowserInstructionCardState();
}

class _BrowserInstructionCardState extends State<_BrowserInstructionCard> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: widget.cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // Header (always visible, tappable)
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: widget.iconColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(widget.icon, color: widget.iconColor, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.browserName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: widget.textPrimaryColor,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 200),
                    turns: _isExpanded ? 0.5 : 0,
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: widget.textSecondaryColor,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Steps (expandable)
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  // Main steps
                  ...widget.steps.asMap().entries.map((entry) {
                    final index = entry.key;
                    final step = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: widget.textSecondaryColor.withValues(
                                alpha: 0.15,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: widget.textSecondaryColor,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              step,
                              style: TextStyle(
                                fontSize: 14,
                                color: widget.textPrimaryColor,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  // Alternative steps section (if provided)
                  if (widget.altTitle != null && widget.altSteps != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      widget.altTitle!,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: widget.textSecondaryColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...widget.altSteps!.asMap().entries.map((entry) {
                      final index = entry.key;
                      final step = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: widget.textSecondaryColor.withValues(
                                  alpha: 0.1,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: widget.textSecondaryColor.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                step,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: widget.textSecondaryColor,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens [BrowserInstructionsSheet] and re-requests permission when the reader
/// taps "check again".
///
/// PROD-4301 — extracted from `chat_screen`'s private `_showBrowserInstructions
/// Sheet`, which was the only way to reach this sheet. The widget was always
/// shared; the *presenter* was not, so a second surface needing it had to
/// duplicate the `showBottomSheetWithHiddenNav` + re-request wiring, and the
/// two copies would drift on the part that matters (whether tapping "check
/// again" actually asks the browser again).
///
/// Web-only by intent. The browser refuses to re-prompt after a denial and
/// there is no app-settings screen to open (`LocationService.canOpenSettings`
/// is false on web), so instructions are the only remaining move — on native,
/// callers open system settings instead.
///
/// [onGranted] runs only when the re-request actually succeeds, so each caller
/// decides what "now we have it" means: chat shares the location, the feed just
/// lets its location gate rebuild.
Future<void> showBrowserLocationInstructions({
  required BuildContext context,
  required WidgetRef ref,
  Future<void> Function()? onGranted,
}) {
  return showBottomSheetWithHiddenNav(
    context: context,
    ref: ref,
    useRootNavigator: true,
    builder: (sheetContext) => BrowserInstructionsSheet(
      onCheckAgain: () async {
        Navigator.pop(sheetContext);
        final status = await ref
            .read(locationProvider.notifier)
            .requestPermissionOnly();
        if (status == LocationPermissionStatus.granted) {
          await onGranted?.call();
        }
      },
    ),
  );
}
