import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/guest_feature_placeholder.dart';

/// Left-side sliding drawer for chat history
/// Matches the Lovable mockup ChatSidebar.tsx exactly
class ChatSidebarDrawer extends ConsumerStatefulWidget {
  const ChatSidebarDrawer({super.key});

  @override
  ConsumerState<ChatSidebarDrawer> createState() => _ChatSidebarDrawerState();
}

class _ChatSidebarDrawerState extends ConsumerState<ChatSidebarDrawer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  // Desktop breakpoint (lg in Tailwind)
  static const double _desktopBreakpoint = 1024;
  // Drawer widths: w-72 (288px) on mobile, md:w-80 (320px) on desktop
  static const double _mobileWidth = 288;
  static const double _desktopWidth = 320;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    // Listen to animation status to trigger rebuilds
    _controller.addStatusListener((status) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSessionSelected(String sessionId) {
    // Track chat history open (Backend analytics)
    ref
        .read(unifiedAnalyticsProvider)
        .trackChatHistoryOpen(sessionId: sessionId);
    // PROD-3168: the sidebar is also a chat entry point — emit chat_open so the
    // chat_open funnel is complete across entry points (kept alongside
    // chat_history_open, which carries the resume/session_id semantics).
    ref
        .read(unifiedAnalyticsProvider)
        .trackChatOpen(entryPoint: EntryPoint.sidebar, sessionId: sessionId);

    ref.read(activeSessionIdProvider.notifier).setActiveSession(sessionId);
    ref.read(chatProvider(sessionId).notifier).loadMessages();
    // Always close drawer on session selection
    ref.read(sidebarOpenProvider.notifier).state = false;
    // Navigate directly to the session
    context.go('/chat/$sessionId');
  }

  void _onNewChat() {
    // PROD-3168: starting a new chat from the sidebar is a chat entry too.
    ref
        .read(unifiedAnalyticsProvider)
        .trackChatOpen(entryPoint: EntryPoint.sidebar);
    // Close drawer and land on the empty chat page. Pre-PROD-1804 this
    // went to `/` (Discovery), which hid the empty-chat WelcomeView
    // behind the discovery surface.
    ref.read(sidebarOpenProvider.notifier).state = false;
    // Clear old active session to prevent flashing previous conversation
    ref.read(activeSessionIdProvider.notifier).setActiveSession(null);
    context.go(AppRoutes.chat);
  }

  void _close() {
    ref.read(sidebarOpenProvider.notifier).state = false;
  }

  void _syncAnimationWithState(bool isOpen) {
    if (isOpen &&
        _controller.status != AnimationStatus.forward &&
        _controller.status != AnimationStatus.completed) {
      _controller.forward();
    } else if (!isOpen &&
        _controller.status != AnimationStatus.reverse &&
        _controller.status != AnimationStatus.dismissed) {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOpen = ref.watch(sidebarOpenProvider);
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= _desktopBreakpoint;
    final drawerWidth = isDesktop ? _desktopWidth : _mobileWidth;

    // Drop any active text-input focus the moment the sidebar opens
    // so the soft keyboard collapses instead of competing with the
    // drawer for screen real-estate. `ref.listen` fires on transitions
    // only (not every build), and this is the single chokepoint every
    // caller of `sidebarOpenProvider` flows through.
    ref.listen<bool>(sidebarOpenProvider, (prev, next) {
      if (next && prev != true) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });

    // Sync animation with state
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncAnimationWithState(isOpen);
    });

    // Don't render anything if closed and animation is done
    if (!isOpen && _controller.isDismissed) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        // Overlay backdrop: bg-background/80 backdrop-blur-sm
        AnimatedBuilder(
          animation: _fadeAnimation,
          builder: (context, child) {
            if (_fadeAnimation.value == 0) {
              return const SizedBox.shrink();
            }
            return GestureDetector(
              onTap: _close,
              child: Container(
                color: Colors.black.withValues(
                  alpha: 0.5 * _fadeAnimation.value,
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 4 * _fadeAnimation.value,
                    sigmaY: 4 * _fadeAnimation.value,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          },
        ),

        // Sliding drawer
        SlideTransition(
          position: _slideAnimation,
          child: _buildDrawerContent(context, drawerWidth, isDesktop),
        ),
      ],
    );
  }

  Widget _buildDrawerContent(
    BuildContext context,
    double width,
    bool isDesktop,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // bg-background in Lovable (warm cream, NOT card/surface)
    final bgColor = isDark ? AppColors.backgroundDark : AppColors.background;
    // border-border in Lovable
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;

    return Container(
      width: width,
      height: double.infinity,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: SafeArea(
        right: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: p-4 border-b border-border
            _buildHeader(context, isDesktop),
            // Sessions list: flex-1 overflow-y-auto p-4
            Expanded(
              child: _SessionsList(onSessionSelected: _onSessionSelected),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isDesktop) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final mutedColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return Container(
      padding: const EdgeInsets.all(16),
      // Border removed to match Lovable mockup
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 1: Title + Close button (close only on mobile: lg:hidden).
          // The session-count badge was removed — the API's
          // `SessionListResponse.total` was unreliable (didn't match the sessions
          // actually shown), so it read as a wrong number. Backend fix tracked in
          // PROD-2914; re-add the badge once the count is trustworthy.
          Row(
            children: [
              // Expanded + ellipsis so the title yields instead of overflowing the
              // sidebar width when the OS large-font setting scales it up
              // (PROD-2907 / § 9 design-system-rules.md).
              Expanded(
                child: Text(
                  l10n.sidebarTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ),
              // Close button - lg:hidden (only on mobile/tablet)
              if (!isDesktop) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _close,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(LucideIcons.x, size: 20, color: mutedColor),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          // Row 2: Full-width New Chat button — outline pill (Lovable: variant="outline" rounded-full)
          Material(
            color: Colors.transparent,
            shape: StadiumBorder(side: BorderSide(color: borderColor)),
            child: InkWell(
              onTap: _onNewChat,
              customBorder: const StadiumBorder(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.plus, size: 16, color: textColor),
                    const SizedBox(width: 10),
                    Text(
                      l10n.sidebarButtonNew,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sessions list widget with infinite scroll support
class _SessionsList extends ConsumerStatefulWidget {
  final Function(String) onSessionSelected;

  const _SessionsList({required this.onSessionSelected});

  @override
  ConsumerState<_SessionsList> createState() => _SessionsListState();
}

class _SessionsListState extends ConsumerState<_SessionsList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Load more when near the bottom (within 200px)
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(sessionsProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAuthenticated = ref.watch(isAuthenticatedProvider);
    final l10n = Lt.of(context);

    // Guest placeholder — no chat history for unauthenticated users
    if (!isAuthenticated) {
      return GuestFeaturePlaceholder(
        icon: LucideIcons.message_square,
        subtitle: l10n.guestChatHistorySubtitle,
        onSignUp: () {
          ref
              .read(unifiedAnalyticsProvider)
              .trackAuthPrompt(
                page: AuthPage.login,
                action: AuthPromptAction.view,
                referrer: AuthReferrer.guestChatHistory,
              );
          navigateToLoginPreservingReturn(
            context,
            ref,
            referrer: AuthReferrer.guestChatHistory,
          );
        },
        compact: true,
      );
    }

    final sessionsState = ref.watch(sessionsProvider);
    final sessions = sessionsState.sessions;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mutedColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    if (sessionsState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Empty state matching Lovable
    if (sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                LucideIcons.message_square,
                size: 32,
                color: mutedColor.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.sidebarEmptyState,
                style: TextStyle(fontSize: 14, color: mutedColor),
              ),
            ],
          ),
        ),
      );
    }

    // Flat list (no group headers) — each item shows its own relative time
    final itemCount = sessions.length + (sessionsState.hasMore ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index >= sessions.length) {
          return _buildLoadingIndicator(sessionsState.isLoadingMore);
        }

        return _SessionItem(
          session: sessions[index],
          onTap: () => widget.onSessionSelected(sessions[index].sessionId),
        );
      },
    );
  }

  Widget _buildLoadingIndicator(bool isLoading) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _SessionItem extends ConsumerWidget {
  final Session session;
  final VoidCallback onTap;

  const _SessionItem({required this.session, required this.onTap});

  /// Compute localized relative time for a session
  String _relativeTime(BuildContext context, Session session) {
    final l10n = Lt.of(context);
    final date = session.lastMessageAt ?? session.createdAt ?? DateTime.now();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final sessionDate = DateTime(date.year, date.month, date.day);
    final diff = today.difference(sessionDate).inDays;

    if (diff == 0) return l10n.chatHistoryToday;
    if (diff == 1) return l10n.chatHistoryYesterday;
    if (diff < 7) return l10n.chatHistoryDaysAgo(diff);
    if (diff < 14) return l10n.chatHistoryLastWeek;
    if (diff < 28) return l10n.chatHistoryWeeksAgo((diff / 7).floor());
    return session.formattedDate;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mutedColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    // Lovable: bg-accent = HSL(350, 30%, 92%) — subtle rose highlight
    const activeColorLight = Color(0xFFF1E4E6);
    final accentColor = isDark
        ? AppColors.surfaceVariantDark
        : activeColorLight;

    final activeSessionId = ref.watch(activeSessionIdProvider);
    final isActive = activeSessionId == session.sessionId;

    final isWhatsApp = session.isWhatsApp;
    const whatsAppColor = AppColors.whatsapp;

    // Use firstMessagePreview as the conversation identifier (title is usually null)
    final title = session.title?.isNotEmpty == true
        ? session.title!
        : session.firstMessagePreview ?? session.formattedDate;
    final time = _relativeTime(context, session);

    // Lovable: space-y-1 (4px gap), px-3 py-2.5 rounded-xl, flex items-center gap-2.5
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          // Lovable: hover:bg-secondary HSL(350 30% 90%) — subtle rose on hover
          hoverColor: isDark
              ? AppColors.surfaceVariantDark
              : AppColors.secondary,
          splashColor: isDark
              ? AppColors.surfaceVariantDark
              : AppColors.secondary,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isActive ? accentColor : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Icon
                Icon(
                  isWhatsApp
                      ? LucideIcons.message_circle
                      : LucideIcons.message_square,
                  size: 16,
                  color: isWhatsApp ? whatsAppColor : mutedColor,
                ),
                const SizedBox(width: 10),
                // Content: title + relative time
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Title row (with optional badges)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: textColor,
                                height: 1.2,
                              ),
                            ),
                          ),
                          // WhatsApp/Read-only badges
                          if (session.isReadOnly) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: mutedColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                l10n.sessionReadOnlyLabel,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: mutedColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ] else if (isWhatsApp) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: whatsAppColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'WhatsApp',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: whatsAppColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      // Relative time
                      const SizedBox(height: 2),
                      Text(
                        time,
                        style: TextStyle(
                          fontSize: 11,
                          color: mutedColor.withValues(alpha: 0.7),
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
