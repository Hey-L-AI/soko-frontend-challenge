import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/orientation_utils.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/glassmorphic_header.dart';
import '../../../shared/widgets/guest_feature_placeholder.dart';
import 'memories_download_helper.dart';

/// Full-screen Memories page showing what Soko has learned about the user
/// Matches the Lovable mockup design with Summary + Key Facts sections
class MemoriesScreen extends ConsumerStatefulWidget {
  const MemoriesScreen({super.key});

  @override
  ConsumerState<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends ConsumerState<MemoriesScreen> {
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    // Load memories when screen opens (only for authenticated users)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final isAuthenticated = ref.read(isAuthenticatedProvider);
      if (!isAuthenticated) return;

      final locale = ref.read(apiLocaleCodeProvider);
      ref.read(memoryProvider.notifier).loadMemory(locale: locale);

      // Track memories page open (Backend analytics)
      ref.read(unifiedAnalyticsProvider).trackMemoriesOpen();
    });
  }

  void _openProfile() {
    context.push(AppRoutes.menu);
  }

  @override
  Widget build(BuildContext context) {
    final isAuthenticated = ref.watch(isAuthenticatedProvider);
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 768;

    // Show guest placeholder for unauthenticated users
    if (!isAuthenticated) {
      return _buildGuestContent(context, l10n, isDark, isDesktop);
    }

    final memoryState = ref.watch(memoryProvider);
    final user = ref.watch(currentUserProvider);
    final hasMemories =
        memoryState.items.isNotEmpty ||
        (memoryState.memory?.memorySummary?.isNotEmpty ?? false) ||
        (memoryState.memory?.memoryText?.isNotEmpty ?? false);

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _PageHeader(
              isDesktop: isDesktop,
              hasMemories: hasMemories && !memoryState.isLoading,
              isDownloading: _isDownloading,
              onAddMore: () => context.go('/'),
              onDownload: () => _downloadMemories(context),
              onOpenProfile: _openProfile,
              userInitial:
                  user?.displayName.substring(0, 1).toUpperCase() ?? 'U',
            ),

            // Content
            Expanded(
              child: memoryState.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      child: Center(
                        // Lovable spec: max-w-2xl = 672px
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 672),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: isDesktop ? 16 : 16,
                              vertical: 16,
                            ),
                            child: hasMemories
                                ? _buildContent(memoryState, l10n, isDark)
                                : _EmptyState(),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(MemoryState memoryState, Lt l10n, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Info Message
        _InfoMessage(),

        const SizedBox(height: 24),

        // Summary Section (always shown, displays memorySummary, falls back to memoryText, or shows empty state)
        _SummarySection(
          summaryText: memoryState.memory?.memorySummary,
          fallbackText: memoryState.memory?.memoryText,
          isLoading: memoryState.isTranslationPending,
        ),
        const SizedBox(height: 24),

        // Memories List Section (if items exist)
        if (memoryState.items.isNotEmpty) ...[
          _MemoriesListSection(
            memories: memoryState.items,
            onDelete: (item) => _deleteItem(item),
            isLoading: memoryState.isTranslationPending,
          ),
          const SizedBox(height: 24),
        ],

        // Download CTA Button
        if (memoryState.items.isNotEmpty ||
            (memoryState.memory?.memoryText?.isNotEmpty ?? false))
          _DownloadCtaButton(
            isLoading: _isDownloading,
            onPressed: () => _downloadMemories(context),
          ),

        // Bottom padding for mobile nav
        if (MediaQuery.of(context).size.width < 1024)
          SizedBox(height: OrientationUtils.bottomNavClearance(context)),
      ],
    );
  }

  Future<void> _deleteItem(MemoryItem item) async {
    // Use the item's original index from when it was created.
    // This is the authoritative index from memoryKeyFacts.
    final factIndex = item.index;

    if (factIndex == null) {
      // Should not happen for items from memoryKeyFacts, but handle gracefully
      showSoko(
        ref,
        message: Lt.of(context).memoriesDeleteError,
        variant: SokoVariant.error,
      );
      return;
    }

    final l10n = Lt.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.memoriesDeleteTitle),
        content: Text(l10n.memoriesDeleteContent(item.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.memoriesDeleteCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(l10n.memoriesDeleteConfirm),
          ),
        ],
      ),
    );

    // Check mounted after dialog dismissal before using ref
    if (!mounted) return;

    if (confirmed == true) {
      final success = await ref
          .read(memoryProvider.notifier)
          .deleteItem(factIndex);

      // Check mounted again after async operation
      if (!mounted) return;

      if (!success) {
        // API error (likely stale data) - refresh and notify user
        // Capture locale before async to avoid ref access issues
        final locale = ref.read(apiLocaleCodeProvider);
        await ref.read(memoryProvider.notifier).loadMemory(locale: locale);

        // Check mounted once more after second async operation
        if (!mounted) return;

        showSoko(
          ref,
          message: l10n.memoriesDeleteError,
          variant: SokoVariant.error,
        );
      }
    }
  }

  Future<void> _downloadMemories(BuildContext context) async {
    if (_isDownloading) return;

    setState(() => _isDownloading = true);

    try {
      final bytes = await ref.read(memoryProvider.notifier).exportMemory();
      final helper = MemoriesDownloadHelper();
      final success = await helper.downloadMemory(bytes, 'heyl-memory.md');

      if (!mounted) return;

      // Track memories download (Backend analytics)
      if (success) {
        ref
            .read(unifiedAnalyticsProvider)
            .trackMemoriesDownload(format: 'markdown');
      }

      final l10n = Lt.of(context);
      showSoko(
        ref,
        message: success
            ? l10n.memoriesDownloadSuccess
            : l10n.memoriesDownloadError,
        variant: success ? SokoVariant.success : SokoVariant.error,
      );
    } catch (e) {
      if (!mounted) return;
      final l10n = Lt.of(context);
      showSoko(
        ref,
        message: l10n.memoriesDownloadError,
        variant: SokoVariant.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  Widget _buildGuestContent(
    BuildContext context,
    Lt l10n,
    bool isDark,
    bool isDesktop,
  ) {
    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header (simplified for guests)
            if (isDesktop)
              GlassmorphicHeader(
                child: Container(
                  decoration: BoxDecoration(
                    color:
                        (isDark
                                ? AppColors.backgroundDark
                                : AppColors.background)
                            .withValues(alpha: 0.8),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 672),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Text(
                              l10n.memoriesTitle.toUpperCase(),
                              style: AppTheme.pageTitle(
                                color: isDark
                                    ? AppColors.textPrimaryDark
                                    : AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Row(
                  children: [
                    Text(
                      l10n.memoriesTitle.toUpperCase(),
                      style: AppTheme.pageTitle(
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),

            // Guest placeholder content
            Expanded(
              child: GuestFeaturePlaceholder(
                icon: LucideIcons.brain,
                subtitle: l10n.guestMemoriesSubtitle,
                onSignUp: () {
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackAuthPrompt(
                        page: AuthPage.login,
                        action: AuthPromptAction.view,
                        referrer: AuthReferrer.guestMemories,
                      );
                  navigateToLoginPreservingReturn(
                    context,
                    ref,
                    referrer: AuthReferrer.guestMemories,
                  );
                },
                compact: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Page header matching Lovable design
/// Mobile: Title row with profile avatar, separator, action buttons below
/// Desktop: Sticky header with title and buttons on same row
class _PageHeader extends StatelessWidget {
  final bool isDesktop;
  final bool hasMemories;
  final bool isDownloading;
  final VoidCallback onAddMore;
  final VoidCallback onDownload;
  final VoidCallback onOpenProfile;
  final String userInitial;

  const _PageHeader({
    required this.isDesktop,
    required this.hasMemories,
    required this.isDownloading,
    required this.onAddMore,
    required this.onDownload,
    required this.onOpenProfile,
    required this.userInitial,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isDesktop) {
      // Desktop header with glassmorphic effect
      // Lovable spec: max-w-2xl = 672px, px-4 = 16px, py-3 = 12px
      return GlassmorphicHeader(
        child: Container(
          decoration: BoxDecoration(
            color: (isDark ? AppColors.backgroundDark : AppColors.background)
                .withValues(alpha: 0.8),
            // Border removed to match Lovable mockup
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 672),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    // Lovable spec: Page title 20px, Bold 700, uppercase, tracking-wider
                    Text(
                      l10n.memoriesTitle.toUpperCase(),
                      style: AppTheme.pageTitle(
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    if (hasMemories) ...[
                      _ActionButton(
                        label: l10n.memoriesAddMore,
                        icon: Icons.auto_awesome,
                        isPrimary: true,
                        onPressed: onAddMore,
                      ),
                      const SizedBox(width: 8),
                      _ActionButton(
                        label: l10n.memoriesDownload,
                        icon: Icons.download_outlined,
                        isPrimary: false,
                        isLoading: isDownloading,
                        onPressed: onDownload,
                      ),
                    ],
                    // No profile avatar on desktop - already in top nav
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Mobile header
    return Column(
      children: [
        // Title row with profile avatar
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Row(
            children: [
              // Lovable spec: Page title 20px, Bold 700, uppercase, tracking-wider
              Text(
                l10n.memoriesTitle.toUpperCase(),
                style: AppTheme.pageTitle(
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              // Profile avatar button
              _ProfileAvatarButton(onTap: onOpenProfile, initial: userInitial),
            ],
          ),
        ),

        // Action buttons row (if memories exist)
        if (hasMemories)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
            child: Row(
              children: [
                _ActionButton(
                  label: l10n.memoriesAddMore,
                  icon: Icons.auto_awesome,
                  isPrimary: true,
                  onPressed: onAddMore,
                ),
                const SizedBox(width: 8),
                _ActionButton(
                  label: l10n.memoriesDownload,
                  icon: Icons.download_outlined,
                  isPrimary: false,
                  isLoading: isDownloading,
                  onPressed: onDownload,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Profile avatar button matching Lovable PageHeader design
/// h-9 w-9 (36px) with ring and shadow
class _ProfileAvatarButton extends StatelessWidget {
  final VoidCallback onTap;
  final String initial;

  const _ProfileAvatarButton({required this.onTap, required this.initial});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, // h-9 w-9
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark
              ? AppColors.sokoPaper.withValues(alpha: 0.2)
              : AppColors.sokoPaper,
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              color: isDark ? AppColors.sokoPaper : AppColors.sokoInk,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Action button for header (Add more / Download)
/// Matches Lovable mockup: size="sm" = h-8 (32px), px-4 (16px), text-xs (12px), icon size-4 (16px)
class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isPrimary;
  final bool isLoading;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.isPrimary,
    this.isLoading = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    if (isPrimary) {
      // Primary pill button (Add more)
      return Material(
        color: primaryColor,
        borderRadius: BorderRadius.circular(100),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(100),
          child: Container(
            height: 32, // h-8
            padding: const EdgeInsets.symmetric(horizontal: 16), // px-4
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: Colors.white), // size-4
                const SizedBox(width: 6), // gap-1.5
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12, // text-xs
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Outline pill button (Download)
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(100),
      child: InkWell(
        onTap: isLoading ? null : onPressed,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          height: 32, // h-8
          padding: const EdgeInsets.symmetric(horizontal: 16), // px-4
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: isDark ? AppColors.borderDarkMode : AppColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary,
                  ),
                )
              else
                Icon(
                  icon,
                  size: 16, // size-4
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              const SizedBox(width: 6), // gap-1.5
              Text(
                label,
                style: TextStyle(
                  fontSize: 12, // text-xs
                  fontWeight: FontWeight.w500,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Info message section with privacy explanation
class _InfoMessage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Text(
            l10n.memoriesInfoTitle,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.memoriesInfoSubtitle,
            style: TextStyle(
              fontSize: 14,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Summary section displaying memorySummary, falling back to memoryText, or empty state message
class _SummarySection extends StatelessWidget {
  final String? summaryText;
  final String? fallbackText;
  final bool isLoading;

  const _SummarySection({
    this.summaryText,
    this.fallbackText,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    // Prefer memorySummary, fall back to memoryText, then show empty state
    final displayText = (summaryText?.isNotEmpty ?? false)
        ? summaryText
        : (fallbackText?.isNotEmpty ?? false)
        ? fallbackText
        : null;
    final hasContent = displayText != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row with icon
        Row(
          children: [
            Icon(Icons.person_outline, size: 16, color: primaryColor),
            const SizedBox(width: 8),
            Text(
              l10n.memoriesSummary,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimary,
              ),
            ),
            if (isLoading) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: primaryColor,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        // Summary card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppColors.surfaceDark : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppColors.borderDarkMode : AppColors.border,
            ),
          ),
          child: Text(
            displayText ?? l10n.memoriesSummaryEmpty,
            style: TextStyle(
              fontSize: 14,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
              height: 1.5,
              fontStyle: hasContent ? FontStyle.normal : FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }
}

/// Memories list section with header and cards
class _MemoriesListSection extends StatelessWidget {
  final List<MemoryItem> memories;
  final Function(MemoryItem) onDelete;
  final bool isLoading;

  const _MemoriesListSection({
    required this.memories,
    required this.onDelete,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row with brain emoji and count
        Row(
          children: [
            const Text('🧠', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Text(
              l10n.memoriesYourMemories,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '(${memories.length})',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
            if (isLoading) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: primaryColor,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        // Memory cards
        ...memories.map(
          (memory) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _MemoryCard(item: memory, onDelete: () => onDelete(memory)),
          ),
        ),
      ],
    );
  }
}

/// Individual memory card with hover delete button
class _MemoryCard extends StatefulWidget {
  final MemoryItem item;
  final VoidCallback onDelete;

  const _MemoryCard({required this.item, required this.onDelete});

  @override
  State<_MemoryCard> createState() => _MemoryCardState();
}

class _MemoryCardState extends State<_MemoryCard> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = !kIsWeb || MediaQuery.of(context).size.width < 768;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.surfaceDark.withValues(alpha: 0.5)
              : AppColors.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: (isDark ? AppColors.borderDarkMode : AppColors.border)
                .withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Text content
            Expanded(
              child: Text(
                widget.item.text,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
            ),

            // Delete button (always visible on mobile, hover on desktop)
            AnimatedOpacity(
              opacity: isMobile || _isHovering ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: InkWell(
                onTap: widget.onDelete,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: AppColors.error,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-width download CTA button
class _DownloadCtaButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onPressed;

  const _DownloadCtaButton({required this.isLoading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.download, size: 18),
        label: Text(l10n.memoriesDownloadAll),
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

/// Empty state when no memories exist
class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = Lt.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 48),
            Text(
              l10n.memoriesEmptyTitle,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.memoriesEmptySubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
