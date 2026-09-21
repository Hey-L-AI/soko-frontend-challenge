import 'package:flutter/widgets.dart';

/// The effective linear text-scale factor for [context], derived from the
/// ambient (app-wide-clamped, see `app.dart`) `MediaQuery` text scaler.
///
/// Use this only for widgets that take a legacy `textScaleFactor: double` and
/// do NOT read `MediaQuery` themselves — chiefly `flutter_linkify`'s
/// `Linkify` / `SelectableLinkify`, whose `textScaleFactor` defaults to `1.0`
/// and would otherwise pin their text at 1× regardless of the OS font-size /
/// Dynamic Type setting (PROD-2875). Plain `Text` already honors the ambient
/// scaler and must NOT be wrapped with this.
///
/// [atFontSize] is the widget's base font size; the factor is measured at that
/// size so non-linear scalers (Android 14) are respected for the size that
/// actually renders.
double effectiveTextScaleFactor(
  BuildContext context, {
  double atFontSize = 15,
}) {
  return MediaQuery.textScalerOf(context).scale(atFontSize) / atFontSize;
}
