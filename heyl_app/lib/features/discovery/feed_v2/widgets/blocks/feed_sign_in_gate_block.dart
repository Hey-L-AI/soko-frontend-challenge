// PROD-4520 — the `sign_in_gate` block: the backend telling a guest to sign in.
//
// **A trigger change, not a new surface.** PROD-4445 built the whole of this —
// the illustration, the Variant C copy in four locales, and the CTA through
// `navigateToLoginPreservingReturn` — and gated it in the app, which never
// called the endpoint for a guest (D9). The backend has since built the guest
// path, so the app now asks like any other filter and renders what comes back.
// `FeedSignInGateState` is reused verbatim; only what decides to show it moved.
//
// So this widget is deliberately thin. Resist giving it its own copy or its own
// CTA: two sign-in gates that drift apart is exactly what reusing the existing
// state prevents.

import 'package:flutter/material.dart';

import '../../../../../data/models/feed_home.dart';
import '../feed_notice_states.dart';
import '../feed_page_content.dart';

class FeedSignInGateBlock extends StatelessWidget {
  final FeedBlockSignInGate block;

  const FeedSignInGateBlock({super.key, required this.block});

  @override
  Widget build(BuildContext context) {
    // `FeedPageContent` for the same reason the screen wrapped it when this was
    // a page-level state: `FeedSignInGateState` draws a full-width notice with
    // `topPadding: 0` and no horizontal margin of its own, so without this its
    // copy runs to the screen edges. Wrapping here keeps the rendered result
    // identical to what PROD-4445 shipped, which is the point — the reader
    // should not be able to tell that the decision moved to the server.
    return FeedPageContent(child: const FeedSignInGateState());
  }
}
