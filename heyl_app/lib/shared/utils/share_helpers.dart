import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../widgets/share_sheet.dart';

/// PROD-2071 — Unified share entry point.
///
/// On web (`kIsWeb`), opens the generic [ShareSheet] (Copy + Share footer)
/// using the caller-supplied [webPreview]. On mobile (iOS/Android), bypasses
/// the sheet entirely and invokes the native share with the URL only — no
/// title, name, or description in the payload.
///
/// Analytics callbacks fire on the corresponding action:
/// - [onCopyAnalytics]: web Copy tap (mobile never triggers this — the native
///   sheet handles copy internally).
/// - [onShareAnalytics]: web Share tap and the mobile native share.
Future<void> shareItem({
  required BuildContext context,
  required WidgetRef ref,
  required String title,
  required String url,
  Widget? webPreview,
  VoidCallback? onCopyAnalytics,
  VoidCallback? onShareAnalytics,
}) async {
  if (kIsWeb) {
    await showShareSheet(
      context: context,
      ref: ref,
      title: title,
      preview: webPreview ?? const SizedBox.shrink(),
      url: url,
      onCopyAnalytics: onCopyAnalytics,
      onShareAnalytics: onShareAnalytics,
    );
    return;
  }

  // Mobile: native share sheet, URL only.
  onShareAnalytics?.call();
  try {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    await Share.share(url, sharePositionOrigin: origin);
  } catch (e) {
    debugPrint('shareItem: error launching native share — $e');
  }
}
