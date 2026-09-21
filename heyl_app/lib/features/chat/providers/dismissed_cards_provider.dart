import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks card IDs the user has dismissed (X tap) inside a chat session.
///
/// Lives in the [ProviderContainer] so it survives `ChatScreen` widget
/// unmount/remount (PROD-2163). Keyed by session ID so each conversation
/// has its own independent dismissal set.
///
/// Frontend-only for now; a backend signal is tracked separately (see the
/// follow-up "store negative card-dismiss signal" feature ticket).
class DismissedCardsNotifier extends StateNotifier<Set<String>> {
  DismissedCardsNotifier() : super(const <String>{});

  void dismiss(String cardId) {
    if (state.contains(cardId)) return;
    state = {...state, cardId};
  }
}

final dismissedCardsProvider =
    StateNotifierProvider.family<DismissedCardsNotifier, Set<String>, String>(
      (ref, sessionId) => DismissedCardsNotifier(),
    );
