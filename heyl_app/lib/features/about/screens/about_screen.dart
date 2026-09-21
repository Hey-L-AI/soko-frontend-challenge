import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/admin_info_box.dart';
import '../../../shared/widgets/scallop_divider.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;

/// `/menu/about` page (PROD-2025). Replaces the legacy `_AboutContent`
/// case inside `ProfileSheet`'s drawer. Mirrors `account_screen.dart`'s
/// shell: `ColoredBox(sokoPaper) → PageContent → SafeArea → Column(
/// _AboutHeader, Expanded(_AboutBody))`. Back button uses
/// `popOrFallback` so deep links work.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AboutHeader(
                title: l10n.aboutTitle,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _AboutBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _AboutHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _AboutHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: const Icon(
                LucideIcons.arrow_left,
                color: AppColors.sokoInk,
              ),
              onPressed: onBack,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            ),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _AboutBody extends ConsumerStatefulWidget {
  const _AboutBody();

  @override
  ConsumerState<_AboutBody> createState() => _AboutBodyState();
}

class _AboutBodyState extends ConsumerState<_AboutBody> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(preferencesProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final user = ref.watch(currentUserProvider);
    final isAdmin = user?.role == UserRole.admin;
    final currentYear = DateTime.now().year;
    final preferences = ref.watch(preferencesProvider).preferences;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                const _AboutHero(),
                if (isAdmin) ...[
                  const SizedBox(height: 12),
                  Center(child: _AdminBuildInfo(userId: user?.userId)),
                ],
                const SizedBox(height: 16),
                Text(
                  l10n.aboutDescription,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 13,
                    fontWeight: FontWeight.w300,
                    height: 1.3,
                    letterSpacing: -0.13,
                    color: AppColors.sokoShade3,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: ScallopDivider(),
                ),
                _AboutLinkRow(
                  leading: const Icon(
                    LucideIcons.file_text,
                    size: 18,
                    color: AppColors.sokoInk,
                  ),
                  title: l10n.aboutTermsOfService,
                  subtitle: _formatAcceptedOn(
                    context,
                    preferences?.termsAcceptedAt,
                  ),
                  onTap: () => context.push(AppRoutes.terms),
                ),
                const SizedBox(height: 8),
                _AboutLinkRow(
                  leading: const Icon(
                    LucideIcons.shield,
                    size: 18,
                    color: AppColors.sokoInk,
                  ),
                  title: l10n.aboutPrivacyPolicy,
                  subtitle: _formatAcceptedOn(
                    context,
                    preferences?.privacyAcceptedAt,
                  ),
                  onTap: () => context.push(AppRoutes.privacy),
                ),
                const SizedBox(height: 8),
                _AboutLinkRow(
                  leading: const Icon(
                    LucideIcons.book_open,
                    size: 18,
                    color: AppColors.sokoInk,
                  ),
                  title: l10n.aboutEula,
                  onTap: () => context.push(AppRoutes.terms),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _SocialCircle(
                    background: const Color(0xFF8B7AE8),
                    icon: const Icon(
                      LucideIcons.instagram,
                      size: 22,
                      color: AppColors.sokoInk,
                    ),
                    semanticLabel: l10n.aboutInstagramHandle,
                    onTap: () =>
                        _launchExternalUrl('https://instagram.com/soko.fyi'),
                  ),
                  const SizedBox(width: 16),
                  _SocialCircle(
                    background: const Color(0xFFC68676),
                    icon: SvgPicture.asset(
                      'assets/images/tiktok.svg',
                      width: 22,
                      height: 22,
                      colorFilter: const ColorFilter.mode(
                        AppColors.sokoInk,
                        BlendMode.srcIn,
                      ),
                    ),
                    semanticLabel: l10n.aboutTiktokHandle,
                    onTap: () =>
                        _launchExternalUrl('https://www.tiktok.com/@soko.fyi'),
                  ),
                  const SizedBox(width: 16),
                  _SocialCircle(
                    background: const Color(0xFFB4DBF4),
                    icon: const Icon(
                      LucideIcons.linkedin,
                      size: 22,
                      color: AppColors.sokoInk,
                    ),
                    semanticLabel: l10n.aboutLinkedinHandle,
                    onTap: () => _launchExternalUrl(
                      'https://www.linkedin.com/company/sokofyi/',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _AboutFooter(year: currentYear),
            ],
          ),
        ),
      ],
    );
  }

  String? _formatAcceptedOn(BuildContext context, DateTime? acceptedAt) {
    if (acceptedAt == null) return null;
    final locale = Localizations.localeOf(context).toString();
    final formatted = DateFormat.yMMMd(locale).format(acceptedAt.toLocal());
    return Lt.of(context).preferencesAcceptedOn(formatted);
  }

  Future<void> _launchExternalUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// Hero block: rounded-square logo tile + "Soko" + version. Sokoised:
/// 80 × 80 rounded square uses `sokoPink` fill + `sokoInk` letter — same
/// palette as the menu-row tinted tiles in `menu_screen.dart`. Version
/// reads from `package_info_plus` at runtime; falls back to "Loading…"
/// while the future resolves so we never render an empty line.
class _AboutHero extends StatelessWidget {
  const _AboutHero();

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.sokoPink,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Center(
            child: Text(
              'S',
              style: TextStyle(
                fontFamily: 'SeasonMix',
                color: AppColors.sokoInk,
                fontSize: 40,
                fontWeight: FontWeight.w400,
                height: 1.0,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Soko',
          style: TextStyle(
            fontFamily: 'SeasonMix',
            fontSize: 32,
            fontWeight: FontWeight.w400,
            height: 1.0,
            letterSpacing: -0.64,
            color: AppColors.sokoInk,
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final version = snapshot.data?.version ?? '1.0.0';
            return Text(
              l10n.aboutVersion(version),
              style: const TextStyle(
                fontFamily: 'Zalando Sans',
                fontSize: 13,
                fontWeight: FontWeight.w300,
                color: AppColors.sokoShade3,
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Soko-tokened link row. Mirrors `_SupportLinkRow` from
/// `support_screen.dart` (sokoShade5 fill, 6 px radius, leading icon,
/// trailing `external_link` glyph).
class _AboutLinkRow extends StatelessWidget {
  const _AboutLinkRow({
    required this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: hasSubtitle ? 10 : 0,
      ),
      child: Row(
        children: [
          SizedBox(width: 18, height: 18, child: Center(child: leading)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    height: 1.2,
                    letterSpacing: -0.14,
                    color: AppColors.sokoInk,
                  ),
                ),
                if (hasSubtitle) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Zalando Sans',
                      fontSize: 13,
                      fontWeight: FontWeight.w300,
                      height: 1.2,
                      color: AppColors.sokoShade3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Icon(
            LucideIcons.external_link,
            size: 18,
            color: AppColors.sokoShade3,
          ),
        ],
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: hasSubtitle ? content : SizedBox(height: 48, child: content),
        ),
      ),
    );
  }
}

/// 48 × 48 circular social button — coloured fill, dark glyph, opens the
/// handle in the OS default browser. Used in the About page's bottom row
/// (PROD-2170 follow-up: icon-only treatment in place of the legacy
/// labelled link rows).
class _SocialCircle extends StatelessWidget {
  final Color background;
  final Widget icon;
  final String semanticLabel;
  final VoidCallback onTap;

  const _SocialCircle({
    required this.background,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(width: 48, height: 48, child: Center(child: icon)),
          ),
        ),
      ),
    );
  }
}

/// Footer: "Made with ❤ in Lisbon" + copyright line. Uses the
/// canonical Soko/Paper secondary text styling (Zalando Sans 12/w300/
/// sokoShade3) so the visual weight stays subordinate to the link rows
/// above.
class _AboutFooter extends StatelessWidget {
  final int year;

  const _AboutFooter({required this.year});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    const footerStyle = TextStyle(
      fontFamily: 'Zalando Sans',
      fontSize: 12,
      fontWeight: FontWeight.w300,
      color: AppColors.sokoShade3,
    );
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(l10n.aboutMadeWith, style: footerStyle),
            const SizedBox(width: 4),
            const Icon(LucideIcons.heart, color: AppColors.sokoRed, size: 14),
            const SizedBox(width: 4),
            Text(l10n.aboutInLisbon, style: footerStyle),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.aboutAllRightsReserved(year),
          style: footerStyle,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Admin-only build info. Renders the canonical `AdminInfoBox` with
/// app version, build date, and rich clipboard text (platform, locale,
/// theme, screen size, timestamp). Visible only to users with
/// [UserRole.admin]; gating happens in `_AboutBody`.
class _AdminBuildInfo extends StatelessWidget {
  final String? userId;

  const _AdminBuildInfo({this.userId});

  String _buildClipboardText(BuildContext context, PackageInfo? packageInfo) {
    final version = packageInfo != null
        ? '${packageInfo.version}+${packageInfo.buildNumber}'
        : 'unknown';
    final buildDate = ApiConstants.buildDate;
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final brightness = Theme.of(context).brightness;
    final locale = Localizations.localeOf(context);
    final platform = kIsWeb ? 'web' : Theme.of(context).platform.name;

    return [
      'App: Soko v$version',
      if (buildDate.isNotEmpty) 'Built: $buildDate',
      'Platform: $platform',
      if (userId != null) 'User ID: $userId',
      'Locale: $locale',
      'Theme: ${brightness == Brightness.dark ? 'dark' : 'light'}',
      'Screen: ${size.width.toInt()}x${size.height.toInt()}',
      'Copied at: ${DateTime.now().toUtc()}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final packageInfo = snapshot.data;
        final buildDate = ApiConstants.buildDate;
        final version = packageInfo != null
            ? 'v${packageInfo.version}+${packageInfo.buildNumber}'
            : 'Loading...';
        final displayText = buildDate.isNotEmpty
            ? '$version · $buildDate'
            : version;

        return AdminInfoBox(
          displayText: displayText,
          clipboardText: _buildClipboardText(context, packageInfo),
        );
      },
    );
  }
}
