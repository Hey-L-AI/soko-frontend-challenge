import 'dart:math' as math;

/// Floor, in km, for the radius a CURATION shelf sends to `/lists/public`.
///
/// Editor picks and city guides are curations of a CITY — "Pastelarias com a
/// Maria José", "Café de especialidade em Lisboa" — so filtering them by the
/// picker's proximity radius asks the wrong question. With no explicit pick the
/// app follows GPS down to the freguesia, and Alvalade's own radius is 1.3 km:
/// that showed 5 of 33 editor picks and hid the "see more", because the page
/// came back short and the shelf correctly concluded there was no more
/// (PROD-3800). City guides were worse — from Barra da Tijuca, zero.
///
/// 50 km rather than the `city` tier's 20 km, measured against production:
///
/// ```
/// Rio (from Barra)   5km→1   10km→1   20km→14   30km→16   50km→16
/// Lisbon (Alvalade)                   20km→17   30km→17   50km→17
/// ```
///
/// A number tuned to Lisbon shortchanges Rio — 20 km still misses two of its
/// curations, 10 km shows ONE — while raising it costs Lisbon nothing, and both
/// curves are flat past ~30 km. 50 leaves headroom for a bigger metro without
/// reaching a neighbouring city's curation.
///
/// Deliberately NOT applied to the proximity shelves (Trending, Mais seguidas,
/// Recomendados, search): being near you is their whole point, and a
/// neighbourhood radius is the correct behaviour there.
///
/// The right shape long-term is the city POLYGON, not a radius — no single
/// number fits Lisbon and CDMX at once. Blocked today: `canContain` requires an
/// explicit area/city pick (GPS is excluded by design) and the client only
/// knows the parent boundary's NAME, not its id.
const double kCurationMinRadiusKm = 50;

/// The radius a curation shelf should request, given the picker's own.
///
/// A FLOOR, not a replacement: a picker set wider than [kCurationMinRadiusKm]
/// keeps its radius, so deliberately widening the scope still works. `null`
/// (no coords) stays null, which the backend reads as an unscoped global query.
double? curationRadiusKm(double? pickerRadiusKm) => pickerRadiusKm == null
    ? kCurationMinRadiusKm
    : math.max(pickerRadiusKm, kCurationMinRadiusKm);
