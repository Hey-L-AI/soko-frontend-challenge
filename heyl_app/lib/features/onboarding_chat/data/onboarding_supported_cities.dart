import 'package:flutter/foundation.dart';

/// A Soko coverage city offered on the not-local step so a user who picked an
/// unsupported place can switch to somewhere we know well. Curated (no backend
/// "list supported cities" endpoint yet) — `name` is the value persisted as
/// `selected_city`; `label` is the chip text.
@immutable
class OnboardingSupportedCity {
  const OnboardingSupportedCity({
    required this.label,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String label; // "Lisboa, PT"
  final String name; // "Lisboa"

  /// City-centre coordinates, sent on a not-local switch so the server can
  /// resolve the switched city (against `discovery_enabled`) and anchor the
  /// preliminary zines on it — otherwise a switched user's zines would fall back
  /// to their (unsupported) device location.
  final double latitude;
  final double longitude;
}

/// The launch coverage cities (Figma "Não sou local ainda").
const onboardingSupportedCities = <OnboardingSupportedCity>[
  OnboardingSupportedCity(
    label: 'Lisboa, PT',
    name: 'Lisboa',
    latitude: 38.7223,
    longitude: -9.1393,
  ),
  OnboardingSupportedCity(
    label: 'Porto, PT',
    name: 'Porto',
    latitude: 41.1579,
    longitude: -8.6291,
  ),
  OnboardingSupportedCity(
    label: 'Rio de Janeiro, BR',
    name: 'Rio de Janeiro',
    latitude: -22.9068,
    longitude: -43.1729,
  ),
  OnboardingSupportedCity(
    label: 'CDMX, MX',
    name: 'Ciudad de México',
    latitude: 19.4326,
    longitude: -99.1332,
  ),
];
