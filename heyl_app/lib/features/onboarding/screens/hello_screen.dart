import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../providers/onboarding_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/auth_header.dart';

/// A segment of text to type in the typewriter animation.
/// If [mistake] is set, the animation will first type the mistake,
/// pause, backspace to erase it, then type the correct [text].
class _TypeSegment {
  final String text;
  final String? mistake;

  const _TypeSegment(this.text, {this.mistake});
}

/// Hello/intro screen with typewriter animation before onboarding tutorial
/// Matches Lovable mockup design with header and pulse cursor
class HelloScreen extends ConsumerStatefulWidget {
  const HelloScreen({super.key});

  @override
  ConsumerState<HelloScreen> createState() => _HelloScreenState();
}

class _HelloScreenState extends ConsumerState<HelloScreen>
    with SingleTickerProviderStateMixin {
  // Displayed text state
  String _displayedText = '';
  bool _isTyping = true;
  bool _showCTA = false;

  // Segment-based typing state
  List<_TypeSegment> _segments = [];
  int _currentSegmentIndex = 0;
  int _charIndexInSegment = 0;
  bool _isErasing = false;
  bool _hasTypedMistake = false;
  String _baseText = ''; // Text from completed segments

  // Generation counter to invalidate stale Future.delayed callbacks
  // when the animation is restarted (e.g., locale change) or skipped.
  int _animationGeneration = 0;

  // Track locale used to build segments (for detecting locale changes)
  Locale? _builtWithLocale;

  // Random for natural variation in timing
  final Random _random = Random();

  // Scroll controller for auto-scroll
  final ScrollController _scrollController = ScrollController();

  // Animation controller for cursor pulse
  late AnimationController _cursorAnimationController;
  late Animation<double> _cursorOpacityAnimation;

  @override
  void initState() {
    super.initState();

    // Track hello screen view (hello_1) and page open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackOnboardingStep(
            step: OnboardingStep.hello1,
            action: OnboardingAction.view,
          );
      ref
          .read(unifiedAnalyticsProvider)
          .trackLoginPageView(page: PreAuthPage.landing);
    });

    // Cursor pulse animation (animate-pulse)
    _cursorAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _cursorOpacityAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _cursorAnimationController,
        curve: Curves.easeInOut,
      ),
    );
    _cursorAnimationController.repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentLocale = Localizations.localeOf(context);

    // Build segments if empty OR if locale changed
    if (_segments.isEmpty || _builtWithLocale != currentLocale) {
      _rebuildForLocale(currentLocale);
    }
  }

  /// Rebuild segments for a new locale, handling animation state properly.
  void _rebuildForLocale(Locale newLocale) {
    _animationGeneration++;
    _builtWithLocale = newLocale;
    _buildSegments();

    // If we haven't started typing yet, just start normally
    if (_displayedText.isEmpty && _isTyping) {
      _startTyping();
      return;
    }

    // If typing is complete, rebuild the full displayed text
    if (!_isTyping) {
      setState(() {
        _displayedText = _segments.map((s) => s.text).join();
      });
      return;
    }

    // If mid-typing, reset and restart from beginning
    setState(() {
      _displayedText = '';
      _baseText = '';
      _currentSegmentIndex = 0;
      _charIndexInSegment = 0;
      _isErasing = false;
      _hasTypedMistake = false;
    });
    _startTyping();
  }

  void _buildSegments() {
    final l10n = Lt.of(context);
    _segments = [
      _TypeSegment('${l10n.helloGreeting}\n\n'),
      _TypeSegment('${l10n.helloIntro}\n'),
      _TypeSegment('${l10n.helloBigThings}\n\n'),
      _TypeSegment('${l10n.helloEventsPlaces} '),
      _TypeSegment(
        '${l10n.helloHiddenGems}\n\n',
        mistake: l10n.helloHiddenGemsMistake,
      ),
      _TypeSegment('${l10n.helloKnowYou}\n'),
      _TypeSegment('${l10n.helloPersonal}\n'),
      // Only add share helps if it's not empty
      if (l10n.helloShareHelps.isNotEmpty)
        _TypeSegment('${l10n.helloShareHelps}\n\n'),
      _TypeSegment('${l10n.helloTimeWithMe}\n'),
      _TypeSegment('${l10n.helloLessPhone}\n'),
      _TypeSegment('${l10n.helloRealLife}\n\n'),
    ];
  }

  void _startTyping() {
    // Small initial delay before starting
    final gen = _animationGeneration;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && _isTyping && _animationGeneration == gen) {
        _typeNextChar();
      }
    });
  }

  void _typeNextChar() {
    if (!mounted || !_isTyping) return;

    if (_currentSegmentIndex >= _segments.length) {
      _onTypingComplete();
      return;
    }

    final segment = _segments[_currentSegmentIndex];

    // Determine which text we're typing
    String textToType;
    if (segment.mistake != null && !_hasTypedMistake) {
      // Type the mistake first
      textToType = segment.mistake!;
    } else {
      // Type the correct text
      textToType = segment.text;
    }

    // Clamp index to valid range to prevent RangeError from async timing issues
    final safeIndex = _charIndexInSegment.clamp(0, textToType.length);

    if (safeIndex < textToType.length) {
      final char = textToType[safeIndex];

      setState(() {
        // Use safeIndex + 1, clamped to text length for safety
        final endIndex = (safeIndex + 1).clamp(0, textToType.length);
        _displayedText = _baseText + textToType.substring(0, endIndex);
        _charIndexInSegment = endIndex;
      });

      // Auto-scroll to bottom
      _autoScroll();

      // Schedule next character with context-aware delay
      _scheduleNextChar(char);
    } else {
      // Segment complete
      _onSegmentTextComplete();
    }
  }

  void _scheduleNextChar(String char) {
    int delay = 30; // Base delay in ms

    // Add delays for punctuation (matching Lovable behavior)
    if (char == '.' || char == '?' || char == '!') {
      delay = 200 + _random.nextInt(150); // 200-350ms for sentence endings
    } else if (char == ',') {
      delay = 80 + _random.nextInt(70); // 80-150ms for commas
    } else if (char == '\n') {
      // Check if it's a paragraph break (double newline)
      if (_displayedText.endsWith('\n\n')) {
        delay = 250 + _random.nextInt(150); // 250-400ms for paragraph breaks
      } else {
        delay = 120 + _random.nextInt(100); // 120-220ms for line breaks
      }
    } else {
      // Regular character with slight variation
      delay = 28 + _random.nextInt(15) - 7; // ~21-35ms
    }

    final gen = _animationGeneration;
    Future.delayed(Duration(milliseconds: delay), () {
      if (mounted && _isTyping && _animationGeneration == gen) {
        _typeNextChar();
      }
    });
  }

  void _onSegmentTextComplete() {
    final segment = _segments[_currentSegmentIndex];

    if (segment.mistake != null && !_hasTypedMistake) {
      // Just finished typing the mistake - pause then erase
      _hasTypedMistake = true;
      _pauseBeforeErase();
    } else {
      // Segment fully complete, move to next
      _baseText = _displayedText;
      _currentSegmentIndex++;
      _charIndexInSegment = 0;
      _hasTypedMistake = false;
      _isErasing = false;

      if (_currentSegmentIndex < _segments.length) {
        _typeNextChar();
      } else {
        _onTypingComplete();
      }
    }
  }

  void _pauseBeforeErase() {
    // 400-600ms pause to let user notice the "mistake"
    final gen = _animationGeneration;
    Future.delayed(Duration(milliseconds: 400 + _random.nextInt(200)), () {
      if (mounted && _isTyping && _animationGeneration == gen) {
        _isErasing = true;
        _eraseChar();
      }
    });
  }

  void _eraseChar() {
    // Guard: must be mounted, typing, and actively erasing
    // The _isErasing check prevents stale async callbacks from running
    // after we've switched to typing the correct text
    if (!mounted || !_isTyping || !_isErasing) return;

    final segment = _segments[_currentSegmentIndex];
    final mistake = segment.mistake;

    // Safety check: ensure we have a mistake to erase and valid index
    if (mistake == null || _charIndexInSegment <= 0) {
      _pauseAfterErase();
      return;
    }

    // Clamp index to valid range to prevent RangeError
    // This handles edge cases where async timing causes index desync
    final safeIndex = _charIndexInSegment.clamp(0, mistake.length);

    if (safeIndex > 0) {
      setState(() {
        _charIndexInSegment = safeIndex - 1;
        _displayedText = _baseText + mistake.substring(0, _charIndexInSegment);
      });

      // Auto-scroll to keep cursor visible
      _autoScroll();

      // Schedule next erase with 35-55ms random delay
      final gen = _animationGeneration;
      Future.delayed(Duration(milliseconds: 35 + _random.nextInt(20)), () {
        if (mounted && _isTyping && _animationGeneration == gen) {
          _eraseChar();
        }
      });
    } else {
      // Done erasing, pause then type correct text
      _pauseAfterErase();
    }
  }

  void _pauseAfterErase() {
    // 150-250ms pause before typing correct text
    final gen = _animationGeneration;
    Future.delayed(Duration(milliseconds: 150 + _random.nextInt(100)), () {
      if (mounted && _isTyping && _animationGeneration == gen) {
        _isErasing = false;
        _charIndexInSegment = 0;
        // hasTypedMistake is already true, so _typeNextChar will type segment.text
        _typeNextChar();
      }
    });
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onTypingComplete() {
    setState(() {
      _isTyping = false;
    });
    final gen = _animationGeneration;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && _animationGeneration == gen) {
        setState(() {
          _showCTA = true;
        });
        _autoScroll();
      }
    });
  }

  void _skipTyping() {
    _animationGeneration++;
    setState(() {
      // Build the full text from all segments (using correct text, not mistakes)
      _displayedText = _segments.map((s) => s.text).join();
      _isTyping = false;
      _showCTA = true;
    });
    _autoScroll();
  }

  void _continueToOnboarding() async {
    // Track advancing to next step
    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(
          step: OnboardingStep.hello1,
          action: OnboardingAction.next,
        );
    if (kIsWeb) {
      // Web: skip carousel and go directly to guest chat.
      // PROD-3210: this path IS onboarding completion on web (the carousel
      // is native-only), but never fired onboarding_complete — hence 7
      // tracked completions vs 2,899 real completers. Web is the majority
      // platform, so this was the whole undercount.
      ref.read(unifiedAnalyticsProvider).trackOnboardingComplete(
        completedSteps: const ['hello_1'],
      );
      await markOnboardingComplete(ref);
      if (mounted) context.go(AppRoutes.home);
    } else {
      context.go('/onboarding');
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _cursorAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // PROD-2073: Soko greeting always renders against the brand palette.
    final primaryColor = AppColors.sokoPink;
    final backgroundColor = AppColors.sokoPaper;
    final textPrimaryColor = AppColors.sokoInk;
    final textSecondaryColor = AppColors.sokoShade3;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: GestureDetector(
        onTap: _isTyping ? _skipTyping : null,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            // Header with language + theme toggle
            const AuthHeader(),

            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: PageContent(
                  child: SizedBox(
                    width: double
                        .infinity, // Always take full width to prevent jumping
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),

                        // Typewriter text - centered
                        // Lovable: font-body text-lg leading-relaxed text-foreground
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: _displayedText),
                              // Cursor with pulse animation - Lovable: w-0.5 h-5 bg-primary ml-0.5 animate-pulse
                              if (_isTyping)
                                WidgetSpan(
                                  child: AnimatedBuilder(
                                    animation: _cursorOpacityAnimation,
                                    builder: (context, child) => Opacity(
                                      opacity: _cursorOpacityAnimation.value,
                                      child: Container(
                                        width: 2, // w-0.5 = 2px
                                        height: 20, // h-5 = 20px
                                        margin: const EdgeInsets.only(
                                          left: 2,
                                        ), // ml-0.5
                                        color: primaryColor,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          style: TextStyle(
                            fontSize: 18, // text-lg
                            height: 1.625, // leading-relaxed
                            color: textPrimaryColor,
                          ),
                          textAlign: TextAlign.left,
                        ),

                        // Inline CTA pill — Soko pink fill, ink text.
                        if (_showCTA)
                          AnimatedOpacity(
                            opacity: _showCTA ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 300),
                            child: GestureDetector(
                              onTap: _continueToOnboarding,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.sokoPink,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  l10n.helloCta,
                                  style: const TextStyle(
                                    color: AppColors.sokoInk,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        const SizedBox(height: 48),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Footer with legal links - Lovable: shrink-0 px-6 py-4 pb-safe border-t border-background
            Container(
              padding: EdgeInsets.fromLTRB(
                24, // px-6
                16, // py-4
                24,
                16 + MediaQuery.of(context).padding.bottom, // pb-safe
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: backgroundColor, width: 1),
                ),
              ),
              child: PageContent(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Brand text - Lovable: text-xs text-muted-foreground
                    Text(
                      l10n.legalFooterBrand,
                      style: TextStyle(
                        fontSize: 12, // text-xs
                        color: textSecondaryColor.withValues(alpha: 0.7),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8), // space-y-2
                    // Legal links - Lovable: flex items-center justify-center gap-4
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: () => context.push(AppRoutes.privacy),
                          child: Text(
                            l10n.legalFooterPrivacy,
                            style: TextStyle(
                              fontSize: 12, // text-xs
                              color: textSecondaryColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16), // gap-4
                        GestureDetector(
                          onTap: () => context.push(AppRoutes.terms),
                          child: Text(
                            l10n.legalFooterTerms,
                            style: TextStyle(
                              fontSize: 12, // text-xs
                              color: textSecondaryColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
