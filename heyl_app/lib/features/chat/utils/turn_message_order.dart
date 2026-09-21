import '../../../data/models/chat_message.dart';
import '../../../data/models/rich_message.dart';

/// Reorders an assistant turn's messages so the user reads the intro text,
/// then the card carousel, then any closing line.
///
/// The backend streams a turn as a sequence of messages and now *leads* with
/// its intro text, emitting the card carousel in-stream after it and a closing
/// line after that (verified on staging for PROD-4032). That streamed order is
/// already the desired one, so it is preserved. The ONLY reorder still wanted
/// is the legacy shape where a carousel is emitted *before any text* in a run:
/// those leading carousels are pulled down to sit just after the first text so
/// the text reads first. Carousels that already follow a text keep their place.
///
/// This replaced an earlier transform that moved *all* carousels to the end of
/// the run, which put the cards after the closing line AND made the carousel
/// the newest message in the turn — re-arming its card-reveal gate when the
/// closing text streamed, so the images hid and re-typed (the PROD-4032 glitch).
///
/// Stable within each run; user messages and overall turn order are untouched.
List<ChatMessage> orderTurnCardsAfterText(List<ChatMessage> messages) {
  final out = <ChatMessage>[];
  var i = 0;
  while (i < messages.length) {
    if (messages[i].isUser) {
      out.add(messages[i]);
      i++;
      continue;
    }
    final start = i;
    while (i < messages.length && messages[i].isAssistant) {
      i++;
    }
    final run = messages.sublist(start, i);

    // Peel off any carousels that lead the run (emitted before any text).
    var j = 0;
    while (j < run.length && run[j].richContent is CardCarouselMessage) {
      j++;
    }
    if (j == 0) {
      // Modern shape: a text (or buttons/image) leads — order is correct.
      out.addAll(run);
    } else if (j < run.length) {
      // Legacy leading carousel(s): first text, then those carousels, then the
      // rest of the run in its streamed order.
      out.add(run[j]);
      out.addAll(run.sublist(0, j));
      out.addAll(run.sublist(j + 1));
    } else {
      // Whole run is carousels — nothing to read first, keep as-is.
      out.addAll(run);
    }
  }
  return out;
}
