import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:heyl_app/providers/api_provider.dart';

/// PROD-4388 — resolve the URL to put in a share sheet.
///
/// Every share surface used to build its own URL locally, producing
/// `app.soko.fyi/events/<uuid>?utm_source=…&utm_content=<uuid>` — ~150
/// characters, six wrapped lines in WhatsApp, and no preview image, because
/// the Flutter SPA shell carries no per-subject Open Graph tags.
///
/// The backend now mints `share.soko.fyi/<kind>/<slug>-<code>` and serves that
/// page itself with real OG tags, so this asks for it instead.
///
/// Three rules, all load-bearing:
///
/// * **Never block the share on the network.** If the call fails or runs long,
///   we share the locally-built URL. A long link is a worse share; a share that
///   silently does nothing is a broken one.
/// * **The budget covers a cold call.** [_kBudget] was 800ms, which production
///   proved too tight: the descriptor answered in 679ms server-side, and with
///   the browser's CORS preflight plus network on top, the client gave up on a
///   response that was already on its way. Users got the long URL while the
///   backend had minted a perfectly good short one. The steady state is now a
///   single indexed read (the short URL is persisted backend-side), so this
///   budget only has to absorb the first share of a subject.
/// * **The server picks the URL.** We read `attribution.share_url` rather than
///   re-deriving `public_url ?? short_url ?? deep_link`, so the preference
///   order lives in one place.
const Duration _kBudget = Duration(milliseconds: 2500);

/// Resolve the share URL for `{shareContext, entityId}`, falling back to
/// [localFallbackUrl] on any failure or timeout.
///
/// [shareContext] is the backend `ShareContext` value — `event`, `venue`,
/// `list`, `list-item`, `daily-drop` or `persona`.
Future<String> resolveShareUrl({
  required WidgetRef ref,
  required String shareContext,
  required String entityId,
  required String localFallbackUrl,
}) async {
  try {
    final api = ref.read(sharesApiProvider);
    final url = await api
        .getShareUrl(shareContext: shareContext, entityId: entityId)
        .timeout(_kBudget);
    if (url.isEmpty) return localFallbackUrl;
    return url;
  } on TimeoutException {
    debugPrint('resolveShareUrl: budget exceeded — sharing the long URL');
    return localFallbackUrl;
  } catch (e) {
    // Includes ShareNotShareable (403): the subject is not shareable, but the
    // user already tapped Share, so hand them the plain link rather than
    // failing the gesture. The backend gates the public page independently.
    debugPrint('resolveShareUrl: falling back to the long URL — $e');
    return localFallbackUrl;
  }
}
