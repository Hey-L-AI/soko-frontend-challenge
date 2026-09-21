// The feed-bundle → see-all "move the whole bundle as one" morph
// (PROD, 2026-09-08).
//
// The bundle block and its see-all page are *almost the same layout*, so the
// open should carry the **whole bundle** — title, the shown rows, their text —
// from its place on the feed into the see-all page as a single unit, rather
// than each thumbnail flying on its own (which read as junk snapping across the
// screen).
//
// **This can't be a `Hero`.** The bundle rows are already `Hero`s (their
// thumbnail flies into the item detail on tap), and Flutter forbids a Hero
// being the descendant of another Hero (`heroes.dart` asserts at build). So a
// single Hero around the block would crash the feed itself. Instead we morph by
// hand: the feed block records its on-screen rectangle on tap
// ([feedBundleMorphSourceRectProvider]), and the see-all page slides its
// matching group (header + highlighted rows) up from that rectangle into place —
// a translation, so nothing scales or distorts. See `FeedBundleSeeAllScreen`.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The feed block's global rectangle, captured the instant its see-all page is
/// opened. Read once by [FeedBundleSeeAllScreen] to seed the group's slide-in,
/// then irrelevant. A single slot is enough: it is set synchronously right
/// before the push, and consumed on the next route's first layout.
final feedBundleMorphSourceRectProvider = StateProvider<Rect?>((ref) => null);
