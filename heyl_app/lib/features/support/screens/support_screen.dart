import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/unified_analytics_service.dart' hide AuthMethod;
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;

/// `/menu/support` page (PROD-2024). Replaces the legacy `_SupportContent`
/// case inside `ProfileSheet`'s drawer. Mirrors `account_screen.dart`'s
/// shell: `ColoredBox(sokoPaper) → PageContent → SafeArea → Column(
/// _SupportHeader, Expanded(_SupportBody))`. Back button uses
/// `popOrFallback` so deep links work.
class SupportScreen extends ConsumerWidget {
  const SupportScreen({super.key});

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
              _SupportHeader(
                title: l10n.supportTitle,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _SupportBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _SupportHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _SupportHeader({required this.title, required this.onBack});

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

class _SupportBody extends ConsumerStatefulWidget {
  const _SupportBody();

  @override
  ConsumerState<_SupportBody> createState() => _SupportBodyState();
}

class _SupportBodyState extends ConsumerState<_SupportBody> {
  SupportInfo? _supportInfo;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Analytics: same event the legacy drawer fired on _navigateToSupport.
      ref.read(unifiedAnalyticsProvider).trackSupportOpen();
    });
    _loadSupportInfo();
  }

  Future<void> _loadSupportInfo() async {
    try {
      final accountApi = ref.read(accountApiProvider);
      final info = await accountApi.getSupportInfo();
      if (!mounted) return;
      setState(() {
        _supportInfo = info;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _openEmail() async {
    final info = _supportInfo;
    if (info == null) return;
    final l10n = Lt.of(context);
    final emailUri = Uri(scheme: 'mailto', path: info.email);
    try {
      if (await canLaunchUrl(emailUri)) {
        ref.read(unifiedAnalyticsProvider).trackSupportEmailClick();
        await launchUrl(emailUri);
        if (!mounted) return;
        showSoko(
          ref,
          message: l10n.supportEmailSent,
          variant: SokoVariant.success,
        );
      } else {
        if (!mounted) return;
        showSoko(
          ref,
          message: l10n.supportEmailError,
          variant: SokoVariant.error,
        );
      }
    } catch (_) {
      if (!mounted) return;
      showSoko(
        ref,
        message: l10n.supportEmailError,
        variant: SokoVariant.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            _error!,
            style: const TextStyle(color: AppColors.sokoInk, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // Section header — D158 typography (icon 20 + label 14/w500/sokoInk).
        Row(
          children: const [
            Icon(LucideIcons.mail, size: 20, color: AppColors.sokoInk),
            SizedBox(width: 8),
            _SectionLabel(),
          ],
        ),
        const SizedBox(height: 12),
        _SupportLinkRow(label: _supportInfo!.email, onTap: _openEmail),
        const SizedBox(height: 8),
        Text(
          l10n.supportSubtitle,
          style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
        ),
        const SizedBox(height: 24),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.sokoLight3,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            l10n.supportResponseInfo,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 13,
              fontWeight: FontWeight.w300,
              height: 1.3,
              letterSpacing: -0.13,
              color: AppColors.sokoInk,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

/// Section header label for the email row. Resolves
/// `supportEmailUs` at build time and matches the canonical
/// `/menu/*` section-header typography (D158): 14 / w500 / sokoInk.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel();

  @override
  Widget build(BuildContext context) {
    return Text(
      Lt.of(context).supportEmailUs,
      style: const TextStyle(
        color: AppColors.sokoInk,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// Soko-tokened external-link row. Visual language mirrors the
/// `_AccountFieldRow` pill on `/menu/account` (sokoShade5 fill, 6 px
/// radius, fixed 48 px height) so the read-only "tap to open" feel
/// reads as one family with the rest of `/menu/*`. Leading mail glyph
/// + sokoInk address + trailing `external_link` glyph signal the
/// outbound action.
class _SupportLinkRow extends StatelessWidget {
  const _SupportLinkRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoShade5,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                const Icon(
                  LucideIcons.mail,
                  size: 18,
                  color: AppColors.sokoInk,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
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
                ),
                const SizedBox(width: 12),
                const Icon(
                  LucideIcons.external_link,
                  size: 18,
                  color: AppColors.sokoShade3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
