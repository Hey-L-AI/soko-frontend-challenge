import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/auth_header.dart';
import '../providers/onboarding_provider.dart';
import '../widgets/onboarding_page_content.dart';

/// Onboarding screen shown to first-time users
/// Matches Lovable mockup design with navigation arrows and header
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  static const _totalPages = 2;

  // Analytics tracking
  late DateTime _screenOpenTime;
  final List<String> _viewedSteps = [];
  // Flag to skip 'view' tracking when navigating via button (already tracked 'next')
  bool _isButtonNavigation = false;

  // Map page index to step name (pages 0,1 map to hello_2, hello_3)
  String _stepForPage(int page) {
    switch (page) {
      case 0:
        return OnboardingStep.hello2;
      case 1:
        return OnboardingStep.hello3;
      default:
        return OnboardingStep.hello2;
    }
  }

  @override
  void initState() {
    super.initState();
    _screenOpenTime = DateTime.now();

    // Track first page view
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _trackPageView(0);
    });
  }

  void _trackPageView(int page) {
    final step = _stepForPage(page);
    if (!_viewedSteps.contains(step)) {
      _viewedSteps.add(step);
    }
    // Skip 'view' tracking if this is from button navigation (already tracked 'next')
    if (_isButtonNavigation) {
      _isButtonNavigation = false;
      return;
    }
    ref.read(unifiedAnalyticsProvider).trackOnboardingStep(
      step: step,
      action: OnboardingAction.view,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _completeOnboarding({bool skipped = false}) async {
    final totalTimeSeconds = DateTime.now().difference(_screenOpenTime).inSeconds;

    // Track completion/skip
    if (skipped) {
      // Track skip action on current step
      ref.read(unifiedAnalyticsProvider).trackOnboardingStep(
        step: _stepForPage(_currentPage),
        action: OnboardingAction.skip,
      );
    }

    // Track onboarding complete with all viewed steps
    // Add hello_1 since user came from hello screen
    final allCompletedSteps = ['hello_1', ..._viewedSteps];
    ref.read(unifiedAnalyticsProvider).trackOnboardingComplete(
      completedSteps: allCompletedSteps,
      skippedAtStep: skipped ? _stepForPage(_currentPage) : null,
      totalTimeSeconds: totalTimeSeconds,
    );

    await markOnboardingComplete(ref);
    if (mounted) {
      context.go(AppRoutes.login);
    }
  }

  void _nextPage() {
    // Track "next" action on current step
    ref.read(unifiedAnalyticsProvider).trackOnboardingStep(
      step: _stepForPage(_currentPage),
      action: OnboardingAction.next,
    );

    if (_currentPage < _totalPages - 1) {
      // Mark as button navigation so onPageChanged doesn't also track 'view'
      _isButtonNavigation = true;
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _completeOnboarding();
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final backgroundColor =
        isDark ? AppColors.backgroundDark : AppColors.background;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final textPrimaryColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final textSecondaryColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;

    final pages = [
      // Feature pages with screenshots - use theme-appropriate images
      OnboardingPageContent(
        imagePath: isDark
            ? 'assets/images/onboarding/onboarding-conversation.png'
            : 'assets/images/onboarding/onboarding-conversation-light.png',
        title: l10n.onboardingTitle1,
        subtitle: l10n.onboardingSubtitle1,
      ),
      OnboardingPageContent(
        imagePath: isDark
            ? 'assets/images/onboarding/onboarding-lists.png'
            : 'assets/images/onboarding/onboarding-lists-light.png',
        title: l10n.onboardingTitle2,
        subtitle: l10n.onboardingSubtitle2,
      ),
    ];

    return Scaffold(
      backgroundColor: backgroundColor,
      body: Column(
        children: [
          // Header with language + theme toggle + skip
          AuthHeader(
            onSkip: () => _completeOnboarding(skipped: true),
            skipLabel: l10n.onboardingSkip,
          ),

          // Page content with navigation arrows
          Expanded(
            child: Row(
              children: [
                // Left arrow
                _NavigationArrow(
                  icon: LucideIcons.chevron_left,
                  onTap: _currentPage > 0 ? _previousPage : null,
                  isEnabled: _currentPage > 0,
                  primaryColor: primaryColor,
                  textSecondaryColor: textSecondaryColor,
                ),

                // Page view (mockup images)
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (index) {
                      setState(() {
                        _currentPage = index;
                      });
                      // Track page view
                      _trackPageView(index);
                    },
                    children: pages,
                  ),
                ),

                // Right arrow
                _NavigationArrow(
                  icon: LucideIcons.chevron_right,
                  onTap: _currentPage < _totalPages - 1 ? _nextPage : null,
                  isEnabled: _currentPage < _totalPages - 1,
                  primaryColor: primaryColor,
                  textSecondaryColor: textSecondaryColor,
                ),
              ],
            ),
          ),

          // Bottom section with indicator and buttons
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // Page indicator
                SmoothPageIndicator(
                  controller: _pageController,
                  count: _totalPages,
                  effect: ExpandingDotsEffect(
                    dotHeight: 8,
                    dotWidth: 8,
                    expansionFactor: 3,
                    spacing: 8,
                    activeDotColor: primaryColor,
                    dotColor: borderColor,
                  ),
                ),
                const SizedBox(height: 24),

                // CTA Buttons - Lovable: max-w-md mx-auto space-y-3 pb-4
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 448), // max-w-md
                  child: Column(
                    children: [
                      // Next/Get Started button (pill shape, foreground color)
                      // Lovable: w-full rounded-full h-12 text-base font-bold
                      SizedBox(
                        width: double.infinity,
                        height: 48, // h-12
                        child: ElevatedButton(
                          onPressed: _nextPage,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: textPrimaryColor,
                            foregroundColor: backgroundColor,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                            elevation: 0,
                          ),
                          child: Text(
                            _currentPage == _totalPages - 1
                                ? l10n.onboardingGetStarted
                                : l10n.onboardingNext,
                            style: const TextStyle(
                              fontSize: 16, // text-base
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12), // space-y-3

                      // "I already know Soko" link
                      // Lovable: w-full text-sm text-primary py-2
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8), // py-2
                        child: GestureDetector(
                          onTap: () => _completeOnboarding(skipped: true),
                          child: Text(
                            l10n.onboardingAlreadyKnow,
                            style: TextStyle(
                              color: primaryColor,
                              fontSize: 14, // text-sm
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Safe area bottom padding
                SizedBox(height: MediaQuery.of(context).padding.bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Navigation arrow button for onboarding
class _NavigationArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool isEnabled;
  final Color primaryColor;
  final Color textSecondaryColor;

  const _NavigationArrow({
    required this.icon,
    required this.onTap,
    required this.isEnabled,
    required this.primaryColor,
    required this.textSecondaryColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 32,
          color: isEnabled ? primaryColor : textSecondaryColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}
