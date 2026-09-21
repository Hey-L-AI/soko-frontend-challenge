import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:heyl_app/l10n/generated/l10n.dart';

/// Shared harness for the PROD-2907 "large font" overflow-guard tests.
///
/// Pumps [child] under a MaterialApp (so theme + `Lt` localizations resolve)
/// with the ambient OS text scaler forced to [textScale] — 1.3× by default, the
/// app-wide clamp ceiling from `app.dart` / D230 that every screen must survive.
/// The scaler is applied via `MediaQuery.of(context).copyWith` so the real
/// `size` / `padding` are preserved; descendants read it through
/// `MediaQuery.textScalerOf` exactly as they do in the running app.
///
/// The child is pinned top-left in a [width]×[height] box (either may be null to
/// leave that axis unconstrained). A deliberately narrow [width] provokes the
/// same layout pressure a small phone at Larger Text hits, so a fixed-size box
/// around scaled text throws a `RenderFlex` overflow — which the test then
/// asserts is absent via `expect(tester.takeException(), isNull)`. (The banner
/// and the thrown `FlutterError` fire under the same `_overflow` condition, so
/// that assertion IS the no-clipping check — no screenshots needed.)
Widget largeFontHarness(
  Widget child, {
  double? width = 360,
  double? height,
  double textScale = 1.3,
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: Lt.localizationsDelegates,
      supportedLocales: Lt.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(textScaler: TextScaler.linear(textScale)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, height: height, child: child),
              ),
            );
          },
        ),
      ),
    ),
  );
}
