import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/utils/defer_provider_write.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../shared/widgets/admin_info_box.dart';
import '../../../shared/widgets/soko_pinned_header.dart';
import '../../../shared/widgets/soko_pinned_header_block.dart';
import '../../item_detail/widgets/item_detail_sheet.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/navigation/detail_siblings.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/chat_items_picker_sheet.dart';
import '../../guest/guest_limits.dart';
import '../../guest/providers/guest_quota_provider.dart';
import '../../legal/providers/ai_consent_provider.dart';
import '../../legal/widgets/ai_disclosure_sheet.dart';
import '../widgets/message_input.dart';
import '../widgets/message_bubble.dart';
import '../../map/providers/map_seed_provider.dart';
import '../../map/utils/map_seed.dart';
import '../widgets/place_cards_row.dart';
import '../widgets/typing_indicator.dart';
import '../widgets/search_status_indicator.dart';
import '../widgets/location_suggestion_card.dart';
import '../widgets/location_sharing_dialog.dart';
import '../widgets/welcome_view.dart';
import '../../discovery/widgets/discovery_chat_bar.dart';
import '../providers/dismissed_cards_provider.dart';
import '../utils/turn_message_order.dart';
import '../../lists/screens/create_zine_screen.dart';
import '../../lists/widgets/add_to_list_sheet.dart';
import '../../../shared/widgets/browser_instructions_sheet.dart';
import '../../../shared/widgets/scallop_divider.dart';
import '../../../core/utils/instagram_url.dart';
import '../../../core/services/push_permission_service.dart';
import '../../../core/services/push_permission_state.dart';
import '../../profile/widgets/push_settings_redirect_sheet.dart';
import '../widgets/instagram_share_suggestion.dart';
import '../widgets/push_suggestion_card.dart';
import '../widgets/chat_debug_panel.dart';

/// Main chat screen - the home page of the app
class ChatScreen extends ConsumerStatefulWidget {
  final String? sessionId;

  /// Optional initial message from the assistant to show when starting a new conversation.
  /// Used when navigating from list detail "Add" button to prompt the user.
  final String? initialAssistantMessage;

  /// Optional second message to show after a delay (milliseconds).
  /// Used for conversational flow when adding items to lists.
  final String? secondAssistantMessage;

  /// Delay in milliseconds before showing the second message. Defaults to 500ms.
  final int secondMessageDelay;

  /// Optional custom placeholder for the message input.
  /// If null, uses the default localized placeholder.
  final String? inputPlaceholder;

  /// Optional message to automatically send when the chat opens.
  /// Used for referral links with pre-filled search queries.
  /// The message will be shown immediately as a user message and sent to the API.
  final String? autoSendMessage;

  const ChatScreen({
    super.key,
    this.sessionId,
    this.initialAssistantMessage,
    this.secondAssistantMessage,
    this.secondMessageDelay = 500,
    this.inputPlaceholder,
    this.autoSendMessage,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  String? _currentSessionId;
  final _scrollController = ScrollController();
  bool _hasInjectedInitialMessage = false;
  bool _showInitialTypingIndicator = false;
  bool _hasAutoSentMessage = false;

  // Pending send state for instant UI transition
  String? _pendingMessageText;
  bool _isPendingSend = false;

  // PROD-713: Scroll lock during agent streaming
  // Prevents scroll from jumping to the bottom when new agent messages arrive
  int _lastMessageCount = 0;
  bool _isAgentStreaming = false;
  bool _userManuallyScrolled = false;

  // PROD-1894: when the user taps "Show more", we want the OPPOSITE of the
  // PROD-713 lock — keep the viewport pinned to the bottom so the incoming
  // assistant cards land in view. Cleared when streaming ends or the user
  // manually scrolls.
  bool _followBottomDuringStream = false;

  // Cancellable timers for initial message injection
  Timer? _initialMessageTimer;
  Timer? _typingIndicatorTimer;
  Timer? _secondMessageTimer;

  // Track whether message input is focused (keyboard visible)
  // Used to hide bottom nav and chat map when keyboard is open
  bool _isInputFocused = false;

  /// Held so [dispose] never has to touch `ref` — `ref.read` inside
  /// `ConsumerState.dispose()` **always throws** (`Bad state: Cannot use "ref"
  /// after the widget was disposed`): `StatefulElement.unmount()` nulls
  /// `_widget` in `super.unmount()` before calling `state.dispose()`, and
  /// riverpod's `_assertNotDisposed` gates on `context.mounted`. The throw is
  /// swallowed by `BuildOwner.finalizeTree()` — so PROD-661's nav restore below
  /// silently never ran, AND every line after it in `dispose()` (the scroll
  /// controller, three timers, `super.dispose()`) was skipped with it. The
  /// notifier is app-scoped and outlives this screen. See
  /// `docs/learnings/ref-read-in-consumerstate-dispose-always-throws.md`.
  StateController<bool>? _bottomNavNotifier;

  // Location suggestion card state
  bool _locationSuggestionDismissed = false;
  bool _hasTrackedLocationSuggestionImpression = false;
  bool _hasTrackedPushSuggestionImpression = false;

  // Card dismiss & create list from conversation state.
  // Dismissed IDs are kept in [dismissedCardsProvider] keyed by sessionId so
  // they survive widget unmount (PROD-2163). Use the [_dismissedCardIds]
  // getter to read them in this widget.
  Set<String> _cardIdsInCreatedList = {};
  String _pendingListName = '';

  /// Assistant message ids whose text has already typed out. Gates the
  /// once-only typewriter + card reveal so the reversed `ListView.builder`
  /// never re-animates an old reply when it scrolls back into view.
  final Set<String> _animatedMessageIds = {};

  /// Assistant message ids whose cards have already been revealed. Once a
  /// turn's cards are on screen they must NEVER hide again — otherwise a
  /// closing text line streamed after the carousel (PROD-4032) flips the
  /// carousel's reveal gate back off, so the images vanish and re-type. This
  /// makes reveal sticky (belt-and-suspenders alongside the turn reorder in
  /// `orderTurnCardsAfterText`).
  final Set<String> _revealedCardMessageIds = {};

  /// Assistant message ids whose cards have already played their entrance
  /// animation. Gates the once-only fade/slide-in so cards don't re-animate on
  /// a later rebuild (closing text streaming in) or when an old turn scrolls
  /// back into view — mirrors [_animatedMessageIds] for the typewriter.
  final Set<String> _cardRevealAnimatedIds = {};

  /// Coordinate cache for event suggestions enriched via
  /// `GET /events/{event_id}`. External/Gemini event cards arrive without
  /// `latitude`/`longitude`, so [_enrichPlacesWithCoords] fetches them on
  /// map open and memoises them here (keyed by `eventId`) so a second map
  /// open doesn't refetch. A `null` value marks an event we already tried
  /// but whose detail carried no coordinates either — don't retry it.
  final Map<String, ({double lat, double lng})?> _eventCoordCache = {};

  /// True when this screen opened onto an EXISTING conversation (deep-link,
  /// sidebar switch, resume) rather than a fresh send / injected first reply.
  /// Set synchronously in [_initializeChatScreen] — before the first build — so
  /// [_buildMessageList] can seed the loaded history as already-animated on the
  /// first frame it has messages, closing the race where the newest reply typed
  /// for a frame before the async seed landed (prefetch/cache path).
  bool _isReopenSession = false;

  /// Guards the reopen history seed to run exactly once (the first build that
  /// actually has messages). Live replies arrive after and stay un-seeded, so
  /// they still type.
  bool _reopenSeededHistory = false;

  /// Dismissed card IDs for the current session. Empty when no active session.
  /// Reads via `ref.read`; subscribe by `ref.watch`-ing the provider in build.
  Set<String> get _dismissedCardIds {
    final id = _currentSessionId;
    if (id == null) return const <String>{};
    return ref.read(dismissedCardsProvider(id));
  }

  @override
  void initState() {
    super.initState();
    _bottomNavNotifier = ref.read(bottomNavVisibleProvider.notifier);
    _initializeChatScreen();
    // Daily drop / weekly bundle init is driven from build() via ref.listen so
    // it still fires when auth state is still loading on first frame.
    // Check if location suggestion was previously dismissed (7-day cooldown)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _locationSuggestionDismissed = ref
          .read(storageServiceProvider)
          .isLocationSuggestionDismissed();
      // Hydrate the guest chat quota from disk so the first send after a
      // cold start sees the persisted count rather than zero. Safe for
      // authenticated users — the gate checks `isAuthenticated` before
      // consulting the state. No-op after the first call.
      // ignore: discarded_futures
      ref.read(guestQuotaProvider.notifier).hydrate();
    });
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Handle navigation to chat with new autoSendMessage (e.g., from referral link
    // or sending from home). GoRouter reuses the widget state instead of recreating
    // it, so we must reset all session-scoped state before starting a new auto-send.
    if (widget.autoSendMessage != null &&
        widget.autoSendMessage != oldWidget.autoSendMessage) {
      debugPrint(
        '[ChatScreen] didUpdateWidget: new autoSendMessage detected: ${widget.autoSendMessage}',
      );
      // Reset session-scoped state for the new auto-send flow
      _hasAutoSentMessage = false;
      _hasInjectedInitialMessage = false;
      _showInitialTypingIndicator = false;
      // Dismissed cards are keyed by sessionId in dismissedCardsProvider —
      // the new session starts with an empty set automatically.
      _cardIdsInCreatedList.clear();
      _pendingListName = '';
      _initialMessageTimer?.cancel();
      _typingIndicatorTimer?.cancel();
      _secondMessageTimer?.cancel();
      // Set pending state to show conversation layout immediately with optimistic message
      _pendingMessageText = widget.autoSendMessage;
      _isPendingSend = true;
      setState(() => _currentSessionId = null);
      ref.read(activeSessionIdProvider.notifier).setActiveSession(null);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _createSessionAndAutoSend();
      });
    }
  }

  @override
  void dispose() {
    // PROD-661: Restore bottom nav if input was focused when navigating away.
    // Uses the notifier captured in [initState]; NEVER reach for `ref` here.
    //
    // Deferred out of the build phase — see [deferProviderWrite]. Capturing the
    // notifier fixes only *reachability*; the field is still a provider, and a
    // write during `Element.unmount` throws and aborts the rest of dispose, so
    // the timers below would silently never be cancelled.
    if (_isInputFocused) {
      final notifier = _bottomNavNotifier;
      deferProviderWrite(() => notifier?.state = true);
    }
    _scrollController.dispose();
    _initialMessageTimer?.cancel();
    _typingIndicatorTimer?.cancel();
    _secondMessageTimer?.cancel();
    super.dispose();
  }

  void _initializeChatScreen() {
    if (widget.sessionId != null) {
      _currentSessionId = widget.sessionId;
      // A deep-linked / switched-to session is a reopen (render history whole)
      // unless we're about to auto-send or inject a fresh first reply — those
      // should type out. Set synchronously, before the first build.
      if (widget.autoSendMessage == null &&
          widget.initialAssistantMessage == null) {
        _isReopenSession = true;
      }
      // Update the active session provider
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(activeSessionIdProvider.notifier)
            .setActiveSession(widget.sessionId);

        // If there's an autoSendMessage, send it immediately
        if (widget.autoSendMessage != null && !_hasAutoSentMessage) {
          _autoSendMessage(widget.sessionId!);
        }
        // If there's an initial assistant message, inject it first
        else if (widget.initialAssistantMessage != null &&
            !_hasInjectedInitialMessage) {
          _injectInitialAssistantMessage(widget.sessionId!);
        } else {
          // Otherwise just load existing messages
          _loadAndSeedHistory(widget.sessionId!);
        }
      });
    } else if (widget.autoSendMessage != null) {
      // Show conversation layout immediately with optimistic message
      _pendingMessageText = widget.autoSendMessage;
      _isPendingSend = true;
      // Auto-send message requires a session - create one first
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _createSessionAndAutoSend();
      });
    } else {
      // On /chat (no sessionId, no autoSend): resume active session if one exists.
      // On / (home): always show hero — don't resume. We check the route in
      // a post-frame callback since GoRouterState needs the widget tree.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final location = GoRouterState.of(context).matchedLocation;
        if (location == '/') {
          // Home route: always show hero, don't resume any session
          return;
        }
        // Chat route: resume active session
        final activeSessionId = ref.read(activeSessionIdProvider);
        if (activeSessionId != null) {
          // Resuming an existing conversation → render history whole.
          _isReopenSession = true;
          setState(() => _currentSessionId = activeSessionId);
          _loadAndSeedHistory(activeSessionId);
        }
      });
    }
  }

  /// Create a session and auto-send the message (for referral flows).
  ///
  /// Guests are capped at `kMaxGuestSessions` session — if they already have
  /// one recorded, reuse it instead of creating a second.
  Future<void> _createSessionAndAutoSend() async {
    if (_hasAutoSentMessage || widget.autoSendMessage == null) return;

    try {
      final isAuthed = ref.read(isAuthenticatedProvider);
      String? sessionId;
      if (!isAuthed) {
        sessionId = ref.read(guestQuotaProvider).sessionId;
      }

      if (sessionId == null) {
        final session = await ref
            .read(sessionsProvider.notifier)
            .createSession();
        if (session == null || !mounted) return;
        sessionId = session.sessionId;
        if (!isAuthed) {
          // ignore: discarded_futures
          ref.read(guestQuotaProvider.notifier).recordSessionCreated(sessionId);
        }
      }

      _resetInputFocusState();
      setState(() {
        _currentSessionId = sessionId;
        // Clear pending state — chatProvider now owns the UI state
        _pendingMessageText = null;
        _isPendingSend = false;
      });
      ref.read(activeSessionIdProvider.notifier).setActiveSession(sessionId);
      _autoSendMessage(sessionId);
    } catch (e) {
      debugPrint('[ChatScreen] Error creating session for auto-send: $e');
      if (mounted) {
        setState(() {
          _pendingMessageText = null;
          _isPendingSend = false;
        });
      }
    }
  }

  /// Auto-send a message (used for referral search links + the home/Discovery
  /// composers, which navigate here with `autoSendMessage`). This is the first
  /// transmission point for a new user, so it gates on AI consent (PROD-2265).
  void _autoSendMessage(String sessionId) {
    if (_hasAutoSentMessage || widget.autoSendMessage == null) return;
    _hasAutoSentMessage = true;

    debugPrint('[ChatScreen] Auto-sending message: ${widget.autoSendMessage}');

    unawaited(_autoSendWithConsent(sessionId, widget.autoSendMessage!));
  }

  Future<void> _autoSendWithConsent(String sessionId, String text) async {
    // PROD-2265 Phase 2: block the first AI transmission until consent. On
    // decline the message is not sent (the user can retype); re-prompts next
    // attempt.
    if (!await _ensureAiConsent()) return;
    if (!mounted) return;

    _bumpGuestQuotaIfNeeded();

    // Send the message via chatProvider - this will:
    // 1. Optimistically add the user message to UI
    // 2. Send to API
    // 3. Stream the response
    ref.read(chatProvider(sessionId).notifier).sendMessage(text);
  }

  /// Inject an initial assistant message into the session with natural stepped timing
  void _injectInitialAssistantMessage(String sessionId) {
    if (_hasInjectedInitialMessage || widget.initialAssistantMessage == null) {
      return;
    }
    _hasInjectedInitialMessage = true;

    // Step 1: Wait 500ms before showing first message
    _initialMessageTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;

      try {
        // Inject the first assistant message into the local cache
        // This message won't be sent to the backend - it's just a UI prompt
        final assistantMessage = ChatMessage.assistantText(
          widget.initialAssistantMessage!,
        );
        ref.read(sessionsApiProvider).addMessage(sessionId, assistantMessage);
        setState(() {});

        // Step 2: If there's a second message, show typing indicator after 500ms
        if (widget.secondAssistantMessage != null) {
          _typingIndicatorTimer = Timer(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            setState(() => _showInitialTypingIndicator = true);

            // Step 3: After 500ms, replace typing indicator with second message
            _secondMessageTimer = Timer(const Duration(milliseconds: 500), () {
              if (!mounted) return;

              try {
                final secondMessage = ChatMessage.assistantText(
                  widget.secondAssistantMessage!,
                );
                ref
                    .read(sessionsApiProvider)
                    .addMessage(sessionId, secondMessage);
                setState(() => _showInitialTypingIndicator = false);
              } catch (e) {
                debugPrint('[ChatScreen] Timer callback failed (disposed): $e');
              }
            });
          });
        }
      } catch (e) {
        debugPrint('[ChatScreen] Timer callback failed (disposed): $e');
      }
    });
  }

  /// PROD-2265 Phase 2 — Apple Guideline 5.1.1(i) / 5.1.2(i) R3. Returns `true`
  /// if the user has already consented to AI processing; otherwise shows the
  /// **blocking** consent sheet and returns the user's choice (persisting
  /// consent on Agree). Callers MUST NOT transmit any data to the AI providers
  /// when this returns `false` — declining re-prompts on the next send attempt.
  /// Bump the guest message counter after a send has cleared the gate and
  /// is about to be transmitted. Increments on submit, not on success —
  /// failed sends therefore burn a slot, but failures are rare and the
  /// alternative requires plumbing a completion callback through
  /// [ChatNotifier] just for the cap. No-op for authenticated users.
  void _bumpGuestQuotaIfNeeded() {
    if (ref.read(isAuthenticatedProvider)) return;
    // ignore: discarded_futures
    ref.read(guestQuotaProvider.notifier).incrementMessageCount();
  }

  Future<bool> _ensureAiConsent() async {
    if (ref.read(aiConsentGrantedProvider)) return true;
    final agreed = await AiDisclosureSheet.showConsent(context, ref);
    if (agreed) {
      await grantAiConsent(ref);
    }
    return agreed;
  }

  Future<String> _ensureSession() async {
    if (_currentSessionId != null) return _currentSessionId!;

    // Guests are capped at `kMaxGuestSessions` session. If they already have
    // a recorded session, route the send into that one instead of creating
    // a second. Authenticated users always create fresh.
    final isAuthed = ref.read(isAuthenticatedProvider);
    if (!isAuthed) {
      final existing = ref.read(guestQuotaProvider).sessionId;
      if (existing != null) {
        _resetInputFocusState();
        setState(() => _currentSessionId = existing);
        try {
          ref.read(activeSessionIdProvider.notifier).setActiveSession(existing);
        } catch (e) {
          debugPrint(
            '[ChatScreen] Could not update activeSessionId (disposed): $e',
          );
        }
        return existing;
      }
    }

    // Create a fresh session - webapp always creates new sessions (no rolling window)
    final session = await ref.read(sessionsProvider.notifier).createSession();
    if (session != null && mounted) {
      // PROD-661: Reset focus state before rebuilding — hero mode MessageInput
      // is about to be replaced by conversation mode MessageInput, and the old
      // FocusNode won't fire a blur event on dispose.
      _resetInputFocusState();
      setState(() => _currentSessionId = session.sessionId);
      try {
        ref
            .read(activeSessionIdProvider.notifier)
            .setActiveSession(session.sessionId);
      } catch (e) {
        debugPrint(
          '[ChatScreen] Could not update activeSessionId (disposed): $e',
        );
      }
      if (!isAuthed) {
        // ignore: discarded_futures
        ref
            .read(guestQuotaProvider.notifier)
            .recordSessionCreated(session.sessionId);
      }
      return session.sessionId;
    }

    throw Exception('Failed to create session');
  }

  /// Gate guest sends against the chat-usage cap.
  ///
  /// Guests are allowed up to [kMaxGuestMessagesPerSession] user-initiated
  /// sends within a single session (`kMaxGuestSessions`). Below the cap,
  /// this returns `false` and the send proceeds; the success path bumps
  /// the counter via [GuestQuotaNotifier.incrementMessageCount]. At or
  /// above the cap, this shows the existing `requireAuth` sheet and
  /// returns `true` so the caller aborts.
  ///
  /// History: PROD-1979 originally blocked every guest send. The backend
  /// has since confirmed guest JWTs are accepted on the message endpoints,
  /// so we let guests try the product for a few turns before gating.
  bool _gateGuestChat() {
    if (ref.read(isAuthenticatedProvider)) return false;
    final quota = ref.read(guestQuotaProvider);
    if (!quota.isAtMessageCap) return false;
    // ignore: discarded_futures
    requireAuth(
      context,
      ref,
      action: Lt.of(context).guestChatSendAction,
      referrer: AuthReferrer.guestChatSend,
      onAuthenticated: () {},
    );
    return true;
  }

  void _onSendMessage(String text) {
    if (text.trim().isEmpty) return;
    if (_gateGuestChat()) return;

    // Check for Instagram URL — offer to share with Soko instead of sending
    final igResult = InstagramUrl.extract(text.trim());
    if (igResult != null && InstagramUrl.isSupported(igResult.type)) {
      final urlTypeName = igResult.type.name;
      showInstagramShareSuggestion(
        context,
        url: igResult.url,
        urlType: igResult.type,
        onSendAsMessage: () {
          ref
              .read(unifiedAnalyticsProvider)
              .trackInstagramShareChatDismiss(urlType: urlTypeName);
          _sendMessageBypassingIgCheck(text);
        },
      );
      return;
    }

    _sendMessageBypassingIgCheck(text);
  }

  /// Sends a message without checking for Instagram URLs (used when the user
  /// explicitly chose "No thanks" in the IG share suggestion dialog).
  void _sendMessageBypassingIgCheck(String text) {
    // If sending from home (/), navigate to /chat with the message as autoSendMessage.
    // This ensures a NEW session is always created — home should never append to
    // an existing conversation. The new ChatScreen handles session creation.
    final location = GoRouterState.of(context).matchedLocation;
    if (location == '/') {
      // Guests with an existing session are capped at `kMaxGuestSessions` —
      // route them into their one session instead of creating a new one.
      final isAuthed = ref.read(isAuthenticatedProvider);
      final guestSessionId = isAuthed
          ? null
          : ref.read(guestQuotaProvider).sessionId;
      if (guestSessionId != null) {
        ref
            .read(activeSessionIdProvider.notifier)
            .setActiveSession(guestSessionId);
        setState(() => _currentSessionId = null);
        context.go('/chat/$guestSessionId', extra: {'autoSendMessage': text});
        return;
      }
      // Clear stale session state to prevent flashing previous conversation
      ref.read(activeSessionIdProvider.notifier).setActiveSession(null);
      setState(() => _currentSessionId = null);
      context.go(AppRoutes.chat, extra: {'autoSendMessage': text});
      return;
    }

    // Non-home: first-message tracking moved to _sendMessageAsync (with session_id)

    // INSTANT: Set pending state to trigger UI transition immediately
    setState(() {
      _pendingMessageText = text;
      _isPendingSend = true;
      // PROD-713: Start scroll lock so new agent messages don't jump to bottom
      _isAgentStreaming = true;
      _userManuallyScrolled = false;
    });

    // Fire async operation without awaiting
    _sendMessageAsync(text);
  }

  Future<void> _sendMessageAsync(String text) async {
    try {
      // PROD-2265 Phase 2: gate the AI transmission on consent. Normally a
      // no-op pass-through (consent was granted on the first-ever send); only
      // shows the sheet if somehow still ungranted. On decline, roll back the
      // optimistic pending state and do not send.
      if (!await _ensureAiConsent()) {
        if (mounted) {
          setState(() {
            _pendingMessageText = null;
            _isPendingSend = false;
            _isAgentStreaming = false;
          });
        }
        return;
      }
      if (!mounted) return;

      final sessionId = await _ensureSession();

      // Clear pending state now that we have a real session
      if (mounted) {
        setState(() {
          _pendingMessageText = null;
          _isPendingSend = false;
        });
      }

      // Check mounted before accessing ref after await
      if (!mounted) return;
      _bumpGuestQuotaIfNeeded();
      await ref.read(chatProvider(sessionId).notifier).sendMessage(text);
    } catch (e) {
      if (mounted) {
        setState(() {
          _pendingMessageText = null;
          _isPendingSend = false;
        });
        showSoko(
          ref,
          message: Lt.of(context).chatErrorSending(e.toString()),
          variant: SokoVariant.error,
        );
      }
    }
  }

  void _onSendVoiceMessage(String audioPath) {
    debugPrint('[ChatScreen] _onSendVoiceMessage called with path: $audioPath');
    if (audioPath.isEmpty) {
      debugPrint('[ChatScreen] Audio path is empty, ignoring');
      return;
    }
    if (_gateGuestChat()) return;

    // First-message tracking moved to _sendVoiceMessageAsync (with session_id)

    // INSTANT: Set pending state to trigger UI transition immediately
    setState(() {
      _isPendingSend = true;
      // PROD-713: Start scroll lock so new agent messages don't jump to bottom
      _isAgentStreaming = true;
      _userManuallyScrolled = false;
    });

    // Fire async operation without awaiting
    _sendVoiceMessageAsync(audioPath);
  }

  Future<void> _sendVoiceMessageAsync(String audioPath) async {
    try {
      // PROD-2265 Phase 2: voice transmits to the AI provider too — gate it.
      if (!await _ensureAiConsent()) {
        if (mounted) setState(() => _isPendingSend = false);
        return;
      }
      if (!mounted) return;

      debugPrint('[ChatScreen] Ensuring session...');
      final sessionId = await _ensureSession();
      debugPrint('[ChatScreen] Session ID: $sessionId');

      // Clear pending state now that we have a real session
      if (mounted) {
        setState(() => _isPendingSend = false);
      }

      // Show sending indicator
      if (mounted) {
        showSoko(
          ref,
          message: Lt.of(context).voiceRecordingSending,
          variant: SokoVariant.info,
          duration: const Duration(seconds: 1),
        );
      }

      // Check mounted before accessing ref after await
      if (!mounted) return;
      _bumpGuestQuotaIfNeeded();
      debugPrint('[ChatScreen] Calling sendVoice...');
      await ref.read(chatProvider(sessionId).notifier).sendVoice(audioPath);
      debugPrint('[ChatScreen] sendVoice completed');
    } catch (e, stackTrace) {
      debugPrint('[ChatScreen] Error sending voice message: $e');
      debugPrint('[ChatScreen] Stack trace: $stackTrace');
      if (mounted) {
        setState(() => _isPendingSend = false);
        showSoko(
          ref,
          message: Lt.of(context).chatErrorSending(e.toString()),
          variant: SokoVariant.error,
        );
      }
    }
  }

  void _onSendImage(String imagePath, String? caption) {
    debugPrint(
      '[ChatScreen] _onSendImage called with path: $imagePath, caption: $caption',
    );
    if (imagePath.isEmpty) {
      debugPrint('[ChatScreen] Image path is empty, ignoring');
      return;
    }
    if (_gateGuestChat()) return;

    // First-message tracking moved to _sendImageAsync (with session_id)

    // INSTANT: Set pending state to trigger UI transition immediately
    setState(() {
      _isPendingSend = true;
      _pendingMessageText = caption;
      // PROD-713: Start scroll lock so new agent messages don't jump to bottom
      _isAgentStreaming = true;
      _userManuallyScrolled = false;
    });

    // Fire async operation without awaiting
    _sendImageAsync(imagePath, caption);
  }

  Future<void> _sendImageAsync(String imagePath, String? caption) async {
    try {
      // PROD-2265 Phase 2: image content transmits to the AI provider — gate it.
      if (!await _ensureAiConsent()) {
        if (mounted) {
          setState(() {
            _pendingMessageText = null;
            _isPendingSend = false;
            _isAgentStreaming = false;
          });
        }
        return;
      }
      if (!mounted) return;

      debugPrint('[ChatScreen] Ensuring session...');
      final sessionId = await _ensureSession();
      debugPrint('[ChatScreen] Session ID: $sessionId');

      // Clear pending state now that we have a real session
      if (mounted) {
        setState(() {
          _pendingMessageText = null;
          _isPendingSend = false;
        });
      }

      // Check mounted before accessing ref after await
      if (!mounted) return;
      _bumpGuestQuotaIfNeeded();
      debugPrint('[ChatScreen] Calling sendImage...');
      await ref
          .read(chatProvider(sessionId).notifier)
          .sendImage(imagePath, caption: caption);
      debugPrint('[ChatScreen] sendImage completed');
    } catch (e, stackTrace) {
      debugPrint('[ChatScreen] Error sending image: $e');
      debugPrint('[ChatScreen] Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _pendingMessageText = null;
          _isPendingSend = false;
        });
        showSoko(
          ref,
          message: Lt.of(context).chatImageSendFailed,
          variant: SokoVariant.error,
        );
      }
    }
  }

  void _openSidebar() {
    ref.read(sidebarOpenProvider.notifier).state = true;
  }

  /// PROD-661: Hide bottom nav (and chat map in session view) when input is focused
  void _onInputFocusChanged(bool focused) {
    if (_isInputFocused == focused) return;
    setState(() => _isInputFocused = focused);
    ref.read(bottomNavVisibleProvider.notifier).state = !focused;
  }

  /// PROD-661: Reset focus state when transitioning between hero and conversation modes.
  /// The old MessageInput's FocusNode is disposed without firing a blur event,
  /// so we must manually restore the bottom nav.
  void _resetInputFocusState() {
    if (_isInputFocused) {
      _isInputFocused = false;
      ref.read(bottomNavVisibleProvider.notifier).state = true;
    }
  }

  Future<void> _onPlaceTapped(
    ItemSuggestion place,
    DetailSiblings siblings, {
    int? resultPosition,
  }) async {
    // Track search result click (fire-and-forget)
    _trackSearchResultClick(place, resultPosition: resultPosition);

    var effectiveSiblings = siblings;

    if (place.type == 'event') {
      final id = place.eventId;
      if (id == null || id.isEmpty) return;
    } else {
      final venueId = place.venueId;
      if (venueId == null || venueId.isEmpty) {
        // PROD-4380: a Google-only place card carries a `google_place_id` but no
        // `venue_id`, so there's no in-app entity to open or add yet. Resolve it
        // to a real venue (creating it from Google on a DB miss — usually a free
        // DB hit once the search's background import has landed), then open the
        // sheet on that venue. `_siblingsForTap` drops these cards, so we build a
        // single-item siblings list for the resolved venue.
        final googlePlaceId = place.googlePlaceId;
        if (googlePlaceId == null || googlePlaceId.isEmpty) return;
        try {
          final resolved =
              await ref.read(venuesApiProvider).resolvePlaceId(googlePlaceId);
          if (!mounted) return;
          final resolvedId =
              (resolved.venueId != null && resolved.venueId!.isNotEmpty)
                  ? resolved.venueId!
                  : resolved.id;
          if (resolvedId.isEmpty) return;
          effectiveSiblings = DetailSiblings(
            items: [
              DetailSibling(type: DetailSiblingType.place, id: resolvedId),
            ],
            currentIndex: 0,
          );
        } catch (e) {
          // A resolve failure leaves the card as-is rather than crashing; the
          // background import will usually have made the retry a DB hit.
          debugPrint('[ChatScreen] resolvePlaceId failed for $googlePlaceId: $e');
          return;
        }
      }
    }

    if (!mounted) return;
    // Open the detail as the same DS bottom sheet the map uses, keeping
    // swipe-between-the-message's-cards inside the sheet (the siblings, already
    // positioned at the tapped card by PlaceCardsRow._siblingsForTap). The
    // `/venues/{id}` `/events/{id}` full-page routes stay for deep links.
    showItemDetailSheet(
      context,
      ref,
      siblings: effectiveSiblings,
      listAddSource: ListSource.chat,
    );
  }

  void _trackSearchResultClick(ItemSuggestion place, {int? resultPosition}) {
    try {
      final intent = place.type == 'event' ? 'search_events' : 'search_places';
      ref
          .read(unifiedAnalyticsProvider)
          .trackSearchResultClick(
            eventId: place.eventId,
            venueId: place.venueId,
            intent: intent,
            resultPosition: resultPosition,
            sessionId: _currentSessionId,
            itemType: place.type,
            itemName: place.name,
            surface: 'chat',
          );
    } catch (e) {
      debugPrint('Analytics: Failed to track search_result_click - $e');
    }
  }

  void _onAddToList(ItemSuggestion place) {
    showAddToListSheet(
      context,
      place,
      ref: ref,
      source: ListSource.chat,
      referrer: AuthReferrer.guestSaveChat,
      // PROD-3873 — quicksave on tap, half-open peek on a fresh save.
      quickSaveIfUnsaved: true,
      skipDrawerWhenSaving: true,
    );
  }

  bool _isPlaceSaved(ItemSuggestion place) {
    // try-catch: this callback can be invoked from surfaces that outlive
    // ChatScreen (e.g. after the user navigates away), so a disposed ref read
    // must degrade gracefully rather than throw.
    try {
      return ref.read(isItemSavedProvider)(
        eventId: place.eventId,
        venueId: place.venueId,
        googlePlaceId: place.googlePlaceId,
      );
    } catch (e) {
      debugPrint('[ChatScreen] _isPlaceSaved failed (disposed): $e');
      return false;
    }
  }

  /// Extract all place suggestions from messages for the map
  List<ItemSuggestion> _getAllItemSuggestions(List<ChatMessage> messages) {
    final suggestions = <ItemSuggestion>[];
    for (final message in messages) {
      if (message.hasItemSuggestions) {
        suggestions.addAll(message.effectiveItemSuggestions);
      }
    }
    // Filter out dismissed cards so map stays in sync
    if (_dismissedCardIds.isNotEmpty) {
      suggestions.removeWhere((s) => _dismissedCardIds.contains(s.id));
    }
    return suggestions;
  }

  /// True for an event suggestion that could be plotted on the map if only
  /// it carried coordinates — i.e. it's an event with a real `eventId` but a
  /// missing `latitude`/`longitude`. External/Gemini event cards match this;
  /// local-DB event cards and place cards already carry coordinates.
  bool _needsCoordEnrichment(ItemSuggestion s) =>
      s.type == 'event' &&
      s.eventId != null &&
      (s.latitude == null || s.longitude == null);

  /// Fill in missing coordinates for event suggestions by fetching
  /// `GET /events/{event_id}` (which resolves the event's venue coords).
  ///
  /// Returns a new list where every enrichable event has coordinates when
  /// the backend had them; everything else is passed through untouched.
  /// Results are memoised in [_eventCoordCache] so reopening the map is
  /// instant, and failures degrade silently (the event just stays
  /// unplotted, exactly as before). Fetches run in parallel.
  Future<List<ItemSuggestion>> _enrichPlacesWithCoords(
    List<ItemSuggestion> places,
  ) async {
    if (!places.any(_needsCoordEnrichment)) return places;
    final detailApi = ref.read(detailApiProvider);
    return Future.wait(
      places.map((s) async {
        if (!_needsCoordEnrichment(s)) return s;
        final eventId = s.eventId!;
        // Cache hit — including a cached `null` (tried before, no coords).
        if (_eventCoordCache.containsKey(eventId)) {
          final cached = _eventCoordCache[eventId];
          return cached == null
              ? s
              : s.copyWith(latitude: cached.lat, longitude: cached.lng);
        }
        try {
          // `source: null` — a coordinate prefetch must not log an interest
          // signal the way an actual detail open does.
          final detail = await detailApi.getEventDetail(eventId);
          final lat = detail.latitude;
          final lng = detail.longitude;
          if (lat != null && lng != null) {
            _eventCoordCache[eventId] = (lat: lat, lng: lng);
            return s.copyWith(latitude: lat, longitude: lng);
          }
          _eventCoordCache[eventId] = null;
        } catch (_) {
          // Network / parse error — leave unplotted, don't cache so a later
          // open can retry.
        }
        return s;
      }),
    );
  }

  /// Whether to show the in-chat location suggestion card.
  /// Only appears when:
  /// 1. Feature flag is enabled
  /// 2. User doesn't have GPS location (IP fallback or no location at all)
  /// 3. User hasn't dismissed it recently (7-day cooldown)
  /// 4. Soko has replied with suggestion cards (places/events) — not plain text
  bool _shouldShowLocationSuggestion(
    List<ChatMessage> messages,
    LocationState locationState,
  ) {
    if (!ref.read(experimentServiceProvider).enableLocationSuggestionCard) {
      return false;
    }
    // Show when user doesn't have GPS — either on IP fallback, or has no
    // location at all (IP geolocation timed out / failed). Don't show if
    // GPS permission is granted (location is just initializing).
    final hasNoGps =
        locationState.isIpFallback ||
        (locationState.lastLocation == null &&
            locationState.permissionStatus != LocationPermissionStatus.granted);
    if (!hasNoGps) return false;
    if (_locationSuggestionDismissed) return false;
    // Only show when Soko has replied with place/event cards
    final hasCardsReply = messages.any(
      (m) => m.isAssistant && m.effectiveCardItems.isNotEmpty,
    );
    if (!hasCardsReply) return false;
    return true;
  }

  /// Get the conversation locale from the last assistant message with a language field.
  /// Returns null if no language is detected (falls back to app locale).
  Locale? _getConversationLocale(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.isAssistant && m.language != null) {
        final code = m.language!;
        final parts = code.split('-');
        return parts.length > 1 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
      }
    }
    return null;
  }

  /// Handle "Share my location" tap on the suggestion card.
  Future<void> _onLocationSuggestionShare() async {
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationSuggestion(action: 'share_tapped');
    final status = await ref
        .read(locationProvider.notifier)
        .requestPermissionOnly();
    if (status == LocationPermissionStatus.granted) {
      // Permission granted — card disappears on rebuild (isIpFallback becomes false)
      if (mounted) setState(() {});
      return;
    }
    // Denial handling — diverges by platform
    if (kIsWeb) {
      // Web: browser won't re-prompt after denial. Show step-by-step instructions.
      _showBrowserInstructionsSheet();
    } else {
      // Native: OS only shows prompt once. Open device Settings so user
      // can enable there. On return, _onAppResumed() detects the change.
      ref.read(locationProvider.notifier).openSettings();
    }
  }

  /// Handle "Not now" tap on the suggestion card.
  void _onLocationSuggestionDismiss() {
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationSuggestion(action: 'dismissed');
    ref.read(storageServiceProvider).saveLocationSuggestionDismissed();
    setState(() => _locationSuggestionDismissed = true);
  }

  /// Handle dismiss (X) tap on a recommendation card.
  /// State lives in [dismissedCardsProvider] so it survives widget unmount.
  void _onCardDismiss(CardItem card, int position) {
    final id = _currentSessionId;
    if (id == null) return;
    ref.read(dismissedCardsProvider(id).notifier).dismiss(card.id);
    // PROD-3209: negative signal — the X on a chat result card is the
    // highest-quality "not this" training signal and was discarded before.
    // [query] is the last user message — the ask these cards answered —
    // so the recommender learns WHAT the rejected card was wrong for.
    String? query;
    for (final m in ref.read(chatProvider(id)).messages.reversed) {
      if (m.isUser && (m.text?.trim().isNotEmpty ?? false)) {
        query = m.text!.trim();
        break;
      }
    }
    ref
        .read(unifiedAnalyticsProvider)
        .trackChatCardDismissed(
          entityId: card.eventId ?? card.venueId ?? card.id,
          entityType: card.type?.name ?? 'unknown',
          position: position,
          sessionId: id,
          query: query,
        );
  }

  /// Collect all non-dismissed card items across all messages
  List<CardItem> _getActiveCardItems(List<ChatMessage> messages) {
    return messages
        .expand((m) => m.effectiveCardItems)
        .where((c) => !_dismissedCardIds.contains(c.id))
        .toList();
  }

  /// Open the chat-items picker so the user can curate which conversation
  /// cards seed the new list, then push the redesigned `CreateZineScreen`
  /// (PROD-1764) with an `onListCreated` hook that bulk-adds only the kept
  /// cards. `showSuccessState: true` keeps the "Ver lista" / "Continuar a
  /// conversa" actions inside the new screen.
  Future<void> _onCreateListFromConversation() async {
    final chatState = ref.read(chatProvider(_currentSessionId ?? ''));
    // Only include cards not already saved to a previously created list
    final activeCards = _getActiveCardItems(
      chatState.messages,
    ).where((c) => !_cardIdsInCreatedList.contains(c.id)).toList();
    if (activeCards.isEmpty) return;

    // PROD-3507: the composer pill (labelled "Turn into a Zine" to users) was
    // tapped and there are cards to build from — record the create-list flow
    // entry (intent), so the tap -> list_create drop-off is measurable.
    ref
        .read(unifiedAnalyticsProvider)
        .trackCreateListFromChat(cardCount: activeCards.length);

    final l10n = Lt.of(context);
    final pickerItems = activeCards.map((c) {
      return PickerItem(
        id: c.id,
        title: c.title,
        imageUrl: c.imageUrl,
        subtitle: _pickerSubtitleForCard(c),
      );
    }).toList();

    final selectedIds = await showChatItemsPickerSheet(
      context: context,
      ref: ref,
      title: l10n.chatCreateListPickerTitle,
      subtitle: l10n.chatCreateListPickerSubtitle(activeCards.length),
      ctaLabel: l10n.chatCreateListPickerContinue,
      items: pickerItems,
    );
    if (!mounted) return;
    if (selectedIds == null || selectedIds.isEmpty) return;

    final keptCards = activeCards
        .where((c) => selectedIds.contains(c.id))
        .toList();
    final keptCardIds = keptCards.map((c) => c.id).toList();
    final initialName = _pendingListName.isNotEmpty ? _pendingListName : null;
    context.push(
      AppRoutes.discoveryListCreate,
      extra: CreateZineRouteExtra(
        initialName: initialName,
        source: ListSource.chat,
        showSuccessState: true,
        onListCreated: (list) async {
          final listsNotifier = ref.read(listsProvider.notifier);
          for (final card in keptCards) {
            final suggestion = card.toItemSuggestion();
            listsNotifier.addToListsOptimistic(
              [list.id],
              suggestion,
              source: ListSource.chat,
              onSuccess: () {},
              onError: (_, __, ___) {},
            );
          }
          if (!mounted) return;
          setState(() {
            _cardIdsInCreatedList.addAll(keptCardIds);
            _pendingListName = '';
          });
        },
      ),
    );
  }

  /// Compact subtitle for a chat card inside the create-list picker. Picks
  /// the most useful single line: subtitle → location → address → city.
  String? _pickerSubtitleForCard(CardItem c) {
    final candidates = <String?>[
      c.subtitle,
      c.location,
      c.address,
      c.neighborhood,
      c.city,
    ];
    for (final v in candidates) {
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Handle postback button tap from ButtonsMessage
  void _onPostback(String text) {
    _onSendMessage(text);
  }

  /// PROD-1894: tap on the "Show more" terminator card in a result
  /// carousel — sends a localized follow-up message in the conversation
  /// asking the assistant for more items, and snaps the chat list to
  /// the bottom (offset 0 in the reverse-mode list) so the user sees
  /// the new user bubble + the assistant's incoming response. Without
  /// this jump the user can tap "Show more" from a position scrolled
  /// well above the latest message and the new content drops in below
  /// the visible viewport.
  void _onShowMoreTap() {
    _followBottomDuringStream = true;
    _onSendMessage(Lt.of(context).chatShowMorePrompt);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _onShareLocation() async {
    final locationState = ref.read(locationProvider);

    // If location not shared yet, show dialog with options
    if (!locationState.isLocationEnabled) {
      _showLocationSharingDialog();
      return;
    }

    // If already sharing, just update location
    final success = await ref.read(locationProvider.notifier).shareOnce();
    _handleLocationShareResult(success);
  }

  void _showPermissionDeniedDialog() {
    // On web, show browser instructions instead of useless "Open Settings" button
    if (kIsWeb) {
      _showBrowserInstructionsSheet();
      return;
    }

    final l10n = Lt.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.locationPermissionRequiredTitle),
        content: Text(l10n.locationPermissionRequiredContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(locationProvider.notifier).openAppSettings();
            },
            child: Text(l10n.locationOpenSettings),
          ),
        ],
      ),
    );
  }

  void _showLocationServicesDisabledDialog() {
    // On web, show browser instructions instead of useless "Open Settings" button
    if (kIsWeb) {
      _showBrowserInstructionsSheet();
      return;
    }

    final l10n = Lt.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.locationServicesDisabledTitle),
        content: Text(l10n.locationServicesDisabledContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(locationProvider.notifier).openLocationSettings();
            },
            child: Text(l10n.locationOpenSettings),
          ),
        ],
      ),
    );
  }

  /// Show browser instructions sheet for enabling location on web
  /// Thin wrapper over the shared presenter (PROD-4301). The sheet was always
  /// a shared widget; the wiring around it used to live here, so the feed's
  /// no-location state could not reuse it without copying the re-request logic.
  void _showBrowserInstructionsSheet() {
    showBrowserLocationInstructions(
      context: context,
      ref: ref,
      onGranted: () async {
        if (!mounted) return;
        // Chat's own follow-up: permission is not the goal here, sharing is.
        final success = await ref.read(locationProvider.notifier).shareOnce();
        _handleLocationShareResult(success);
      },
    );
  }

  void _showLocationSharingDialog() {
    LocationSharingDialog.show(
      context: context,
      onShareOnce: () async {
        final success = await ref.read(locationProvider.notifier).shareOnce();
        _handleLocationShareResult(success);
      },
      onShareAlways: () async {
        final success = await ref
            .read(locationProvider.notifier)
            .enableAlwaysShare();
        _handleLocationShareResult(success);
      },
    );
  }

  void _handleLocationShareResult(bool success) {
    if (!mounted) return;

    final locationState = ref.read(locationProvider);

    if (success) {
      showSoko(
        ref,
        message: Lt.of(context).locationShared,
        variant: SokoVariant.success,
        duration: const Duration(seconds: 2),
      );
    } else if (locationState.permissionStatus ==
        LocationPermissionStatus.deniedForever) {
      _showPermissionDeniedDialog();
    } else if (locationState.permissionStatus ==
        LocationPermissionStatus.serviceDisabled) {
      _showLocationServicesDisabledDialog();
    } else if (kIsWeb && locationState.error != null) {
      // On web, show browser instructions for any location error
      // since the user can't fix it without changing browser/OS settings
      _showBrowserInstructionsSheet();
    } else if (locationState.error != null) {
      showSoko(ref, message: locationState.error!, variant: SokoVariant.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);

    // Watch activeSessionIdProvider and sync with local state.
    //
    // PROD-1736: post-cutover [ChatScreen] only mounts on `/chat[/...]`
    // routes (canonical home `/` now mounts `DiscoveryScreen` under
    // `DiscoveryShell`). The previous home-route hero branch is gone —
    // any in-flight bookmarks to `/` land on Discovery, not the chat
    // hero. The session-sync logic below covers the only remaining case:
    // session changed externally (e.g. from `ChatSidebarDrawer`).
    final location = GoRouterState.of(context).matchedLocation;

    final activeSessionId = ref.watch(activeSessionIdProvider);
    final effectiveSessionId = activeSessionId ?? _currentSessionId;

    if (activeSessionId != _currentSessionId) {
      // Session changed externally - sync local state
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (activeSessionId != _currentSessionId) {
          debugPrint(
            '[ChatScreen] Syncing _currentSessionId from provider: $_currentSessionId -> $activeSessionId',
          );
          setState(() {
            _currentSessionId = activeSessionId;
          });
        }
      });
    }

    final chatState = effectiveSessionId != null
        ? ref.watch(chatProvider(effectiveSessionId))
        : const ChatState();
    // Subscribe to dismissed-card changes so X-tap rebuilds the list and map.
    // Reads inside helpers go through the `_dismissedCardIds` getter; this
    // watch is what triggers the rebuild when the set changes.
    if (effectiveSessionId != null) {
      ref.watch(dismissedCardsProvider(effectiveSessionId));
    }
    final locationState = ref.watch(locationProvider);

    // PROD-713: Listen for streaming state changes to preserve scroll position.
    // ref.listen fires synchronously before the rebuild, giving us a reliable
    // point to capture the scroll extent before new content shifts the layout.
    if (effectiveSessionId != null) {
      ref.listen<ChatState>(chatProvider(effectiveSessionId), (previous, next) {
        if (previous == null) return;

        // Detect streaming start
        if (!previous.isStreaming && next.isStreaming) {
          _isAgentStreaming = true;
          _userManuallyScrolled = false;
          // PROD-2699: follow the bottom by default for every user-initiated
          // stream (normal message + Show more), so the latest results are
          // shown. Cleared if the user scrolls up to read history.
          _followBottomDuringStream = true;
          _lastMessageCount = next.messages.length;
          return;
        }

        // Detect streaming end
        if (previous.isStreaming && !next.isStreaming) {
          _isAgentStreaming = false;
          _userManuallyScrolled = false;
          _followBottomDuringStream = false;
          return;
        }

        // Post-stream settle: after a live turn finishes, the provider clears
        // the streamed messages (client-generated ids like `msg_<ts>_assistant`)
        // and refetches the same turn from the API under real server ids
        // (chat_provider.dart: clearMessages + _fetchMessages). Every animation
        // guard here is keyed by messageId, so that id swap makes them all miss
        // and the just-typed reply re-typewrites while its cards re-reveal and
        // reload. Everything present once streaming has ended has already been
        // shown, so mark the refetched ids as already-animated/revealed. Gated
        // on new ids appearing while NOT streaming/sending, so it fires only on
        // the refetch (and the harmless reopen/error-recovery fetch), never on a
        // genuinely new streamed reply (which arrives with isStreaming == true).
        if (!next.isStreaming && !next.isSending) {
          final previousIds = previous.messages.map((m) => m.messageId).toSet();
          final hasNewIds = next.messages.any(
            (m) => !previousIds.contains(m.messageId),
          );
          if (hasNewIds) {
            for (final message in next.messages) {
              _animatedMessageIds.add(message.messageId);
              _revealedCardMessageIds.add(message.messageId);
              _cardRevealAnimatedIds.add(message.messageId);
            }
          }
        }

        // During streaming, follow the bottom when new messages arrive so the
        // latest results stay visible (PROD-1894 for "Show more", PROD-2699 for
        // normal responses). If the user scrolled up to read history,
        // _followBottomDuringStream is cleared and we leave the view put.
        if (_isAgentStreaming && !_userManuallyScrolled) {
          final newCount = next.messages.length;
          if (newCount > _lastMessageCount) {
            if (_followBottomDuringStream) {
              // Stick to offset 0 (bottom of the reverse list). The
              // ScrollMetricsNotification listener re-pins as the cards grow.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted ||
                    !_scrollController.hasClients ||
                    !_followBottomDuringStream) {
                  return;
                }
                _scrollController.jumpTo(0);
              });
            }
            _lastMessageCount = newCount;
          }
        }
      });
    }

    // Get the active session to check if it's a WhatsApp/read-only session
    final activeSession = ref.watch(activeSessionProvider);
    // Watch saved state to rebuild when items are saved/unsaved
    // This ensures PlaceCardsRow cards update their isSaved indicator after saving
    ref.watch(
      listsProvider.select(
        (s) => (s.savedEventIds, s.savedVenueIds, s.savedGooglePlaceIds),
      ),
    );

    // Show conversation layout when:
    // 1. We have messages to display
    // 2. We're sending/streaming (creating new messages)
    // 3. We have an existing session selected (loading or loaded)
    // This ensures clicking a session from sidebar immediately shows conversation view
    final hasMessages =
        chatState.messages.isNotEmpty ||
        chatState.isSending ||
        chatState.isStreaming ||
        _isPendingSend ||
        effectiveSessionId !=
            null; // Show conversation layout for any selected session

    debugPrint(
      '[ChatScreen] build: route=$location, effectiveSessionId=$effectiveSessionId, hasMessages=$hasMessages, isLoading=${chatState.isLoading}, msgCount=${chatState.messages.length}',
    );

    // Desktop breakpoint — kept here for the conversation-layout
    // header/spacing branches below. Pre-PROD-1736 the desktop branch
    // also drove an `ImmersiveMapHero` hero-mode path on `/` plus the
    // `DesktopTopNav` mount in `MainShell`; both retired at cutover.
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 1024;

    // Empty/welcome state: no active session, no messages, nothing in
    // flight. Switches the layout to WelcomeView (input in the middle,
    // starters below, no map) instead of the traditional bottom-pinned
    // input + map column used during conversation.
    final isEmptyState =
        chatState.messages.isEmpty &&
        !chatState.isSending &&
        !chatState.isStreaming &&
        !_isPendingSend &&
        effectiveSessionId == null;

    // PROD-1894: admin info chip now lives inside the conversation header
    // (rendered both on mobile and desktop), and the header itself is no
    // longer mobile-only. The "Create list" CTA moved into the chat-bar
    // bottom row (see [MessageInput.showCreateList]) — the standalone
    // banner that used to sit above the input is gone.

    // Conversation state: Show traditional layout
    // Desktop: constrain all content to central column (max-w-2xl = 672px)
    Widget conversationContent = Column(
      children: [
        // Pinned header (D118 `SokoPinnedHeader`, fixed placement). Renders
        // in BOTH the empty and conversation states: left = recent-chats
        // drawer, centre = location, right = memories. The admin session
        // chip is preserved as an extra row under the bar for admins.
        _buildPinnedHeaderBlock(
          context,
          user,
          activeSession: activeSession,
          effectiveSessionId: effectiveSessionId,
          messageCount: chatState.messages.length,
        ),

        // Empty/welcome state owns its own layout (input in the middle,
        // starters below, no map) — see WelcomeView. The map and the
        // bottom-pinned input only render in the conversation state.
        if (isEmptyState)
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 672),
                child: WelcomeView(
                  // Reuse the Discovery composer — same component, same
                  // typewriter placeholders, same Hero animation. On
                  // send, `DiscoveryChatBar` calls `context.go('/chat',
                  // extra: {'autoSendMessage': text})` which (since we're
                  // already on /chat) lands in `didUpdateWidget` and
                  // triggers `_autoSendMessage`, creating the session
                  // and streaming the response (PROD-1804).
                  //
                  // History moved to the header's left button (recent-chats
                  // drawer), so the empty-state composer no longer hosts the
                  // History strip. It opts into the leading clear/search
                  // affordance to match the Figma empty frame (`7507:28135`).
                  inputWidget: DiscoveryChatBar(
                    autofocus: !isDesktop,
                    outlined: true,
                  ),
                ),
              ),
            ),
          )
        else ...[
          // Messages area - same width as bottom section for alignment
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 672,
                ), // max-w-2xl - same as input
                // PERFORMANCE: Only show loading when loading an existing session
                // If we have messages or are streaming, show the message list
                child:
                    chatState.isLoading &&
                        chatState.messages.isEmpty &&
                        !chatState.isStreaming
                    ? const Center(child: CircularProgressIndicator())
                    : _buildMessageList(
                        chatState.messages,
                        chatState.isSending,
                        chatState.isStreaming,
                        chatState.streamingText,
                        searchStatusText: chatState.searchStatusText,
                        showTypingIndicator: _showInitialTypingIndicator,
                      ),
              ),
            ),
          ),

          // Bottom section (map + input) - same width as messages
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 672), // max-w-2xl
              child: Builder(
                builder: (context) {
                  // PROD-4100: the always-on 104 px map preview strip is
                  // gone. The only map entry point is now the pink map
                  // button in the composer, shown only when this session
                  // has results, opening the full-screen map with all of
                  // them.
                  final mapPlaces = _getAllItemSuggestions(chatState.messages);
                  final hasResults = mapPlaces.isNotEmpty;

                  return Column(
                    children: [
                      // "Continue on WhatsApp" button for active WhatsApp sessions
                      if (activeSession?.whatsappContinueUrl != null)
                        _buildContinueOnWhatsAppButton(
                          context,
                          activeSession!.whatsappContinueUrl!,
                        ),

                      // Soko-Ink scallop motif rendered immediately above
                      // the message input — anchors the composer to the
                      // page-level Soko vocabulary already used by the
                      // Discovery scallop. Inset 16 px to align with the
                      // input's horizontal padding.
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: ScallopDivider(),
                      ),
                      // Message input (disabled for WhatsApp sessions). The
                      // 8pt bottom padding mirrors the map's 8pt bottom margin
                      // above the input — giving the same visible gap below
                      // the input (above the DiscoveryShell nav slot, and
                      // above the soft keyboard when focused).
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 16,
                          right: 16,
                          bottom: 8,
                        ),
                        child: MessageInput(
                          onSend: _onSendMessage,
                          onVoiceSend: _onSendVoiceMessage,
                          onShareLocation: _onShareLocation,
                          isLoading:
                              chatState.isSending ||
                              chatState.isStreaming ||
                              _isPendingSend,
                          isLocationSharing: locationState.isSharing,
                          uploadProgress: chatState.uploadProgress,
                          autofocus: widget.initialAssistantMessage != null,
                          placeholder: widget.inputPlaceholder,
                          disabled: activeSession?.canSendMessages == false,
                          // The chat composer now matches Figma exactly: a
                          // single input row (+ map button), no bottom strip.
                          // The "Create list" / Turn-into-a-Zine pill and the
                          // search-location label are removed from the input;
                          // the create-list flow (_onCreateListFromConversation)
                          // stays wired for a future entry point elsewhere.
                          showCreateList: false,
                          onCreateList: _onCreateListFromConversation,
                          // History moved to the header's left button
                          // (recent-chats drawer), so the composer no longer
                          // hosts the "Recents" pill either.
                          showHistory: false,
                          // Pink map button — only when the session has
                          // results; opens the full map with all of them.
                          // Event cards from the external/Gemini source arrive
                          // without coordinates, so enrich them via
                          // `GET /events/{event_id}` before opening so they
                          // actually plot instead of dropping to "0 places".
                          showMapButton: hasResults,
                          onOpenMap: hasResults
                              ? () async {
                                  final enriched =
                                      await _enrichPlacesWithCoords(mapPlaces);
                                  if (!context.mounted) return;
                                  // Open the SAME map as `/map`, seeded with the
                                  // chat's places. The seed rides a root
                                  // provider (not `extra`, which web tab-refocus
                                  // drops); the map pipeline branches on it.
                                  // Cleared after pop.
                                  ref.read(mapSeedProvider.notifier).state =
                                      SeededMapData.fromItems(enriched);
                                  try {
                                    await context.push(AppRoutes.chatMap);
                                  } finally {
                                    ref.read(mapSeedProvider.notifier).state =
                                        null;
                                  }
                                }
                              : null,
                          onFocusChanged: _onInputFocusChanged,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],

        // Bottom inset for the input. Post-PROD-1736 the chat always
        // mounts under [DiscoveryShell] whose `Scaffold.bottomNavigationBar`
        // slot already reserves the nav height + iOS safe-area-bottom
        // outside the body — so we add NO nav clearance here. The 8pt
        // visible gap between input and nav (and between input and the
        // soft keyboard when focused) is owned by the input's own bottom
        // padding above. The keyboard inset SizedBox below rides the
        // input above the soft keyboard on focus.
        //
        // NOT animated — iOS animates viewInsets.bottom as the keyboard
        // slides; adding our own animation causes overshoot.
        if (!isDesktop)
          SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
      ],
    );

    // Tap-outside-to-dismiss is owned by the global `GestureDetector` in
    // `MaterialApp.builder` (see app.dart). Don't add a local wrapper —
    // PROD-1804 documented that stacking a second translucent
    // GestureDetector with `onTap: unfocus` races the TextField's focus on
    // first tap (user had to tap twice).

    // Center the entire chat column (header + messages + input) inside the
    // app-standard [PageContent] max-width column, so chat respects the same
    // desktop cap ([PageLayout.desktopContentMaxWidth]) as every other
    // surface instead of the wider bespoke 672 px it used to use. Below
    // [PageLayout.desktopBreakpoint] (phones) this is full-bleed, unchanged.
    // The header now sits in the same column as the body (no more
    // "full-bleed top, centered middle" asymmetry). The inner
    // ConstrainedBox(maxWidth: 672)s around the messages and bottom section
    // remain but are inert under this narrower cap.
    return Stack(
      children: [
        PageContent(child: conversationContent),
        const ChatDebugTab(),
        const ChatDebugPanel(),
      ],
    );
  }

  /// The app's pinned header (D118 `SokoPinnedHeader`) composed in the shared
  /// `SokoPinnedHeaderBlock`: full-bleed paper + top safe-area inset + 15 px
  /// above/below the 40 px bar, identical to the feed's block. Rendered in
  /// BOTH the empty and conversation states.
  ///
  /// The bar itself is inset horizontally by `kSokoPageMargin` so its icons
  /// line up with the feed header (the block's paper stays full-bleed). The
  /// feed does this via `FeedPageContent`; chat's whole column already sits in
  /// `PageContent`, so it only needs the horizontal padding, not a second cap.
  ///
  /// Chat's message list is `reverse: true`, so this uses the *fixed*
  /// placement idea — the header sits above the list (outside the scroll
  /// view), never overlays it, and does no scroll maths. No backdrop blur:
  /// the solid-paper block doesn't overlay scrolling content, so blur would
  /// be inert (it existed on the old translucent header).
  ///
  /// Slots: left = recent-chats drawer (`_openSidebar`), centre = location,
  /// right = memories (`/menu/memory`). The admin session-info chip is
  /// preserved as the block's `below` row (6 px gap) for admins.
  Widget _buildPinnedHeaderBlock(
    BuildContext context,
    dynamic user, {
    Session? activeSession,
    String? effectiveSessionId,
    required int messageCount,
  }) {
    final showAdminChip =
        user?.role == UserRole.admin && effectiveSessionId != null;
    // Memories is a per-account surface. Show the brain button to signed-in
    // users only; guests have no persistent twin and the route bounces them,
    // so a button would dead-end.
    final isAuthed = ref.watch(isAuthenticatedProvider);

    return SokoPinnedHeaderBlock(
      below: showAdminChip
          ? (
              widget: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kSokoPageMargin,
                ),
                child: _AdminSessionInfo(
                  session: activeSession,
                  sessionId: effectiveSessionId,
                  userId: user?.userId,
                  messageCount: messageCount,
                ),
              ),
              gap: 6,
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kSokoPageMargin),
        child: SokoPinnedHeader(
          leading: SokoHeaderSlot.icon(
            icon: LucideIcons.list,
            semanticLabel: Lt.of(context).chatHeaderRecentChatsLabel,
            onTap: _openSidebar,
          ),
          centre: SokoHeaderSlot.location(),
          trailing: isAuthed
              ? SokoHeaderSlot.memories(
                  onTap: () => context.push(AppRoutes.memory),
                )
              : null,
        ),
      ),
    );
  }

  /// Copy an assistant message's text to the clipboard (long-press / right-
  /// click on the bubble). Replaces the retired per-message feedback toolbar
  /// which previously bundled this action (PROD-2913).
  void _onCopyMessageText(BuildContext context, String messageId) {
    final sessionId = _currentSessionId;
    if (sessionId == null) return;

    final chatState = ref.read(chatProvider(sessionId));
    final messages = chatState.messages.where((m) => m.messageId == messageId);
    final message = messages.isNotEmpty ? messages.first : null;

    if (message != null) {
      final text = message.displayText ?? '';
      if (text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
        showSoko(
          ref,
          message: Lt.of(context).feedbackTextCopied,
          variant: SokoVariant.info,
          duration: const Duration(seconds: 2),
        );
      }
    }
  }

  /// Load an existing session's history and mark all of it as already-animated,
  /// so re-opening a conversation renders whole (no typewriter). Only messages
  /// that arrive AFTER this — a fresh session's first reply, or a live reply
  /// after the user sends — remain un-seeded and type out.
  void _loadAndSeedHistory(String id) {
    ref.read(chatProvider(id).notifier).loadMessages().then((_) {
      if (!mounted) return;
      _animatedMessageIds.addAll(
        ref.read(chatProvider(id)).messages.map((m) => m.messageId),
      );
    });
  }

  Widget _buildMessageList(
    List<ChatMessage> messages,
    bool isSending,
    bool isStreaming,
    String? streamingText, {
    String? searchStatusText,
    bool showTypingIndicator = false,
  }) {
    // Reopened conversation: on the first build that actually has messages,
    // seed every loaded id as already-animated BEFORE any bubble is built, so
    // the newest reply renders whole instead of typing for a frame (the
    // prefetch/cache race). Runs once; live replies arrive later un-seeded and
    // still type out.
    if (_isReopenSession && !_reopenSeededHistory && messages.isNotEmpty) {
      _animatedMessageIds.addAll(messages.map((m) => m.messageId));
      _reopenSeededHistory = true;
    }
    // Create display messages with pending message if needed
    var displayMessages = [...messages];

    // Show pending message optimistically when no real messages yet
    if (_isPendingSend && _pendingMessageText != null && messages.isEmpty) {
      displayMessages.add(ChatMessage.userText(_pendingMessageText!));
    }

    // Preserve each turn's streamed order (intro text → cards → closing line);
    // only a legacy carousel emitted before any text is pulled below the first
    // text. See orderTurnCardsAfterText (PROD-4032).
    displayMessages = orderTurnCardsAfterText(displayMessages);

    // PROD-1894: locate the latest assistant message that still has
    // non-dismissed cards — only that message gets the "Show more"
    // terminator card. Pre-1894 polish: we used to gate on the absolute
    // latest message, but the assistant frequently streams a text-only
    // follow-up bubble after the carousel, leaving the card-bearing
    // message no-longer-latest and suppressing the terminator. Walking
    // backwards is O(N) worst case but exits on the first match.
    String? latestCardMessageId;
    for (int i = displayMessages.length - 1; i >= 0; i--) {
      final m = displayMessages[i];
      if (!m.isAssistant) continue;
      final hasCards = m.effectiveCardItems.any(
        (c) => !_dismissedCardIds.contains(c.id),
      );
      if (hasCards) {
        latestCardMessageId = m.messageId;
        break;
      }
    }

    // Newest assistant message overall (after the cards-after-text reorder this
    // is usually a turn's trailing card carousel) and the newest assistant
    // message that carries TYPED TEXT. Only the latter types out; the former's
    // cards wait for that type-out.
    String? latestAssistantMessageId;
    String? latestAssistantTextId;
    for (int i = displayMessages.length - 1; i >= 0; i--) {
      final m = displayMessages[i];
      if (!m.isAssistant) continue;
      latestAssistantMessageId ??= m.messageId;
      final rich = m.richContent;
      final text = rich is TextRichMessage
          ? rich.content
          : rich is ButtonsMessage
          ? rich.text
          : (rich is CardCarouselMessage || rich is ImageRichMessage)
          ? ''
          : (m.text ?? '');
      if (text.isNotEmpty) {
        latestAssistantTextId = m.messageId;
        break;
      }
    }
    // The newest turn's text is still typing → hold its cards (and any trailing
    // carousel) until it finishes.
    final newestTextPending =
        latestAssistantTextId != null &&
        !_animatedMessageIds.contains(latestAssistantTextId);

    // Add 1 to item count if sending, pending, streaming, or showing initial typing indicator
    final showExtra =
        isSending || isStreaming || showTypingIndicator || _isPendingSend;
    final showLocationSuggestion = _shouldShowLocationSuggestion(
      displayMessages,
      ref.read(locationProvider),
    );
    final pushUi = ref.watch(pushPermissionServiceProvider);
    final showPushSuggestion = PushPermissionService.shouldShowCard(pushUi);
    final extraItemCount =
        (showExtra ? 1 : 0) +
        (showLocationSuggestion ? 1 : 0) +
        (showPushSuggestion ? 1 : 0);
    final itemCount = displayMessages.length + extraItemCount;

    // Track location suggestion impression once when it first renders
    if (showLocationSuggestion && !_hasTrackedLocationSuggestionImpression) {
      _hasTrackedLocationSuggestionImpression = true;
      ref
          .read(unifiedAnalyticsProvider)
          .trackLocationSuggestion(action: 'impression');
    }

    if (showPushSuggestion && !_hasTrackedPushSuggestionImpression) {
      _hasTrackedPushSuggestionImpression = true;
      ref
          .read(unifiedAnalyticsProvider)
          .trackPushSuggestion(action: 'shown', source: 'chat_card');
    }

    // PROD-713: Detect user-initiated scrolls during streaming to stop
    // compensating. UserScrollNotification fires only for user gestures,
    // not for our programmatic jumpTo calls.
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (_isAgentStreaming) _userManuallyScrolled = true;
        // PROD-1894: a manual scroll during a Show-more stream means the
        // user is reading something else — stop force-pinning to the bottom.
        _followBottomDuringStream = false;
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          // With reverse: true, index 0 is at the bottom of the screen
          // Show typing indicator at index 0 (bottom of reversed list)
          if (showExtra && index == 0) {
            if (isStreaming &&
                streamingText != null &&
                streamingText.isNotEmpty) {
              // Show streaming text as a temporary assistant message
              // Order is reversed visually: indicator at top, message below
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TypingIndicator(),
                  const SizedBox(height: 8),
                  MessageBubble(
                    message: ChatMessage.assistantText(streamingText),
                  ),
                ],
              );
            }
            // Show search status text when available, otherwise generic dots
            if (searchStatusText != null) {
              return SearchStatusIndicator(text: searchStatusText);
            }
            return const TypingIndicator();
          }

          // Location suggestion card — appears just after typing indicator
          final suggestionIndex = showExtra ? 1 : 0;
          if (showLocationSuggestion && index == suggestionIndex) {
            final conversationLocale = _getConversationLocale(displayMessages);
            Widget card = LocationSuggestionCard(
              onShareLocation: _onLocationSuggestionShare,
              onDismiss: _onLocationSuggestionDismiss,
            );
            if (conversationLocale != null) {
              card = Localizations.override(
                context: context,
                locale: conversationLocale,
                child: card,
              );
            }
            return card;
          }

          final pushSuggestionIndex =
              (showExtra ? 1 : 0) + (showLocationSuggestion ? 1 : 0);
          if (showPushSuggestion && index == pushSuggestionIndex) {
            final ready = pushUi.permission as PushPermissionReady;
            return PushSuggestionCard(
              sub: ready.sub,
              onPrimary: () async {
                if (ready.sub == ReadySubState.osDenied) {
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackPushSuggestion(
                        action: 'tapped',
                        source: 'chat_card',
                        authStatus: 'denied',
                      );
                  await PushSettingsRedirectSheet.show(
                    context,
                    source: 'chat_card',
                  );
                } else {
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackPushSuggestion(
                        action: 'tapped',
                        source: 'chat_card',
                        authStatus: 'notDetermined',
                      );
                  await ref
                      .read(pushPermissionServiceProvider.notifier)
                      .requestAndRegister(source: 'chat_card');
                }
              },
              onDismiss: () async {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackPushSuggestion(
                      action: 'dismissed',
                      source: 'chat_card',
                    );
                await ref
                    .read(pushPermissionServiceProvider.notifier)
                    .dismissCard();
              },
            );
          }

          // Calculate message index accounting for extra items and reversed order
          final adjustedIndex = index - extraItemCount;
          final messageIndex = displayMessages.length - 1 - adjustedIndex;
          final message = displayMessages[messageIndex];

          // Use effectiveCardItems to get CardItem list directly,
          // filtering out dismissed cards
          final cardItems = message.effectiveCardItems
              .where((c) => !_dismissedCardIds.contains(c.id))
              .toList();

          // CardCarouselMessage is rendered as carousel only (no bubble needed)
          final isCardCarouselOnly = message.richContent is CardCarouselMessage;

          // Grouping context for Instagram-style user-bubble corners. On screen
          // (reversed list): the message ABOVE is older (messageIndex-1), the one
          // BELOW is newer (messageIndex+1).
          final prevIsUser =
              messageIndex > 0 && displayMessages[messageIndex - 1].isUser;
          final nextIsUser =
              messageIndex < displayMessages.length - 1 &&
              displayMessages[messageIndex + 1].isUser;

          // Only the newest assistant TEXT reply types out, and only until it
          // has animated once (guards against re-animating on scroll-back). A
          // buttons message types its prompt; carousel/image messages have no
          // leading text, so they never type.
          final animateTypewriter =
              message.isAssistant &&
              message.messageId == latestAssistantTextId &&
              !_animatedMessageIds.contains(message.messageId);
          // ALL of the newest turn's attached content (its own cards here, its
          // buttons inside the MessageBubble, and any trailing card carousel
          // reordered to the end of the turn) waits until that turn's text has
          // typed out. Older turns, user messages, and no-text turns reveal now.
          final isNewestAssistant =
              message.messageId == latestAssistantMessageId;
          // Reveal is STICKY: once a turn's cards have shown they stay shown,
          // even if a closing text line streams afterwards and briefly re-arms
          // the gate (PROD-4032). Otherwise the images vanish and re-type.
          final cardsRevealed =
              _revealedCardMessageIds.contains(message.messageId) ||
              !(isNewestAssistant && newestTextPending);
          // Remember the first frame a turn's cards render, so the reveal
          // stays sticky on subsequent rebuilds (idempotent Set add; no
          // setState — the value only matters for later builds, which any
          // real state change already triggers).
          final showCards = cardItems.isNotEmpty && cardsRevealed;
          if (showCards) {
            _revealedCardMessageIds.add(message.messageId);
          }
          // Play the fade/slide-in exactly once, on the first frame the cards
          // appear (after the text has typed out). Guard against re-animating
          // on a later rebuild or on scroll-back, and skip under reduce-motion.
          final animateCardsReveal =
              showCards &&
              !_cardRevealAnimatedIds.contains(message.messageId) &&
              !MediaQuery.of(context).disableAnimations;
          if (showCards) {
            _cardRevealAnimatedIds.add(message.messageId);
          }

          Widget messageColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Skip the bubble for a pure card carousel (cards are the message).
              if (!isCardCarouselOnly)
                MessageBubble(
                  message: message,
                  onPostback: _onPostback,
                  onCardTap: (place, siblings) =>
                      _onPlaceTapped(place, siblings),
                  onCardBookmark: _onAddToList,
                  isCardSaved: _isPlaceSaved,
                  prevIsUser: prevIsUser,
                  nextIsUser: nextIsUser,
                  animateTypewriter: animateTypewriter,
                  onTextRevealed: () {
                    if (!mounted ||
                        _animatedMessageIds.contains(message.messageId)) {
                      return;
                    }
                    setState(() => _animatedMessageIds.add(message.messageId));
                  },
                ),
              // Cards below the text, revealed only after it types out, and
              // faded/slid in once (matching the bubble entrance).
              if (showCards) ...[
                const SizedBox(height: 12),
                Align(
                  key: ValueKey('cards_${message.messageId}'),
                  alignment: Alignment.centerLeft,
                  child: PlaceCardsRow(
                    items: cardItems,
                    // Staggered one-card-at-a-time reveal on the first frame
                    // the cards appear for this turn (incl. reopen); settled on
                    // later rebuilds / scroll-back (guarded by animateCardsReveal).
                    animate: animateCardsReveal,
                    onTap: (place, siblings) => _onPlaceTapped(place, siblings),
                    onDismiss: _onCardDismiss,
                    // PROD-1894: terminator only on the latest assistant
                    // reply that still carries cards (resilient to a text-
                    // only bubble streamed after the carousel).
                    onShowMore: message.messageId == latestCardMessageId
                        ? _onShowMoreTap
                        : null,
                  ),
                ),
              ],
            ],
          );

          // Long-press (mobile) / right-click (desktop web) an assistant reply
          // to copy its text. Replaces the retired feedback toolbar (PROD-2913).
          if (message.isAssistant) {
            messageColumn = GestureDetector(
              onLongPress: () => _onCopyMessageText(context, message.messageId),
              onSecondaryTapUp: (_) =>
                  _onCopyMessageText(context, message.messageId),
              child: messageColumn,
            );
          }

          return messageColumn;
        },
      ),
    );
  }

  /// Build the "Continue on WhatsApp" button for WhatsApp sessions
  Widget _buildContinueOnWhatsAppButton(
    BuildContext context,
    String whatsappUrl,
  ) {
    final l10n = Lt.of(context);
    const whatsAppColor = AppColors.whatsapp;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: whatsAppColor,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: () => _openWhatsAppLink(whatsappUrl),
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.chat, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  l10n.sessionContinueOnWhatsApp,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Open the WhatsApp deep link with prefilled greeting message
  Future<void> _openWhatsAppLink(String url) async {
    // Get localized greeting message
    final greeting = Lt.of(context).homeWhatsAppGreeting;

    // Try to get phone from user profile (more reliable)
    final user = ref.read(currentUserProvider);
    final phone = user?.whatsappPhone;

    Uri uri;
    if (phone != null && phone.isNotEmpty) {
      // Use user profile's phone number (backend provides locale-aware number)
      uri = Uri.https('wa.me', '/$phone', {'text': greeting});
    } else {
      // Fall back to session URL with appended greeting
      final encodedGreeting = Uri.encodeComponent(greeting);
      uri = Uri.parse('$url?text=$encodedGreeting');
    }

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[ChatScreen] Failed to open WhatsApp link: $e');
      if (mounted) {
        showSoko(
          ref,
          message: 'Could not open WhatsApp',
          variant: SokoVariant.error,
        );
      }
    }
  }
}

/// Admin-only session info chip rendered inside the conversation header
/// (PROD-1894). Was a full-width strip below the header pre-1894.
class _AdminSessionInfo extends StatelessWidget {
  final Session? session;
  final String sessionId;
  final String? userId;
  final int messageCount;

  const _AdminSessionInfo({
    required this.session,
    required this.sessionId,
    required this.userId,
    required this.messageCount,
  });

  String _buildClipboardText(PackageInfo? packageInfo) {
    final version = packageInfo != null
        ? '${packageInfo.version}+${packageInfo.buildNumber}'
        : 'unknown';
    final buildDate = ApiConstants.buildDate;
    final lines = <String>[
      'Session ID: $sessionId',
      if (userId != null) 'User ID: $userId',
      if (session != null) 'Channel: ${session!.channel.name}',
      if (session?.createdAt != null) 'Created: ${session!.createdAt!.toUtc()}',
      if (session?.lastMessageAt != null)
        'Last message: ${session!.lastMessageAt!.toUtc()}',
      'Messages: $messageCount',
      'Build: v$version',
      if (buildDate.isNotEmpty) 'Built: $buildDate',
      'Copied at: ${DateTime.now().toUtc()}',
      'Platform: ${kIsWeb ? 'web' : 'mobile'}',
    ];
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    // Truncate session ID for display
    final truncated = sessionId.length > 12
        ? '${sessionId.substring(0, 12)}...'
        : sessionId;

    // PROD-1894 polish: mobile gets the compact chip (lock + label +
    // actions only); desktop keeps the truncated session ID inline.
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        return AdminInfoBox(
          displayText: 'Session: $truncated',
          clipboardText: _buildClipboardText(snapshot.data),
          showDisplayText: isDesktop,
        );
      },
    );
  }
}
