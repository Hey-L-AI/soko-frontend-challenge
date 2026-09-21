/// Caps applied to a guest's chat usage before they must sign in.
///
/// A guest may create at most [kMaxGuestSessions] chat session(s) and send
/// at most [kMaxGuestMessagesPerSession] user-initiated messages within
/// that session. After either cap is reached, the existing `requireAuth`
/// sheet gates further sends. Counts persist per `visitor_id` so a reload
/// can't reset them; they clear on successful sign-in.
const int kMaxGuestSessions = 1;
const int kMaxGuestMessagesPerSession = 5;
