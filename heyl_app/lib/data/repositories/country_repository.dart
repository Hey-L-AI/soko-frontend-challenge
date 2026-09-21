import '../../shared/utils/diacritic_fold.dart';
import '../models/country.dart';

/// Repository providing country data for phone number input
class CountryRepository {
  CountryRepository._();

  /// Default country (Portugal)
  static const Country defaultCountry = Country(
    name: 'Portugal',
    isoCode: 'PT',
    dialCode: '+351',
    flag: '\u{1F1F5}\u{1F1F9}',
  );

  /// Find a country by its ISO code (e.g., "BR", "PT", "US")
  /// Returns null if not found.
  static Country? findByIsoCode(String isoCode) {
    final upperCode = isoCode.toUpperCase();
    // Check popular countries first (faster lookup for common cases)
    for (final country in popularCountries) {
      if (country.isoCode == upperCode) return country;
    }
    // Then check all countries
    for (final country in _allCountriesSorted) {
      if (country.isoCode == upperCode) return country;
    }
    return null;
  }

  /// Find a country by its English name — case- and diacritic-insensitive,
  /// exact match. Returns null if not found.
  ///
  /// Resolves the backend's reverse-geocoded country NAME to an ISO-2 across
  /// ALL countries, not just launch markets. Needed because
  /// `LocationState.resolvedCountryCode` is an uppercased full country name
  /// (e.g. "FINLAND"), not an ISO-2 code — see
  /// `docs/learnings/location-provider-resolvedcountrycode-is-uppercase-name.md`.
  static Country? findByName(String name) {
    final folded = foldDiacritics(name).toLowerCase().trim();
    if (folded.isEmpty) return null;
    for (final country in popularCountries) {
      if (foldDiacritics(country.name).toLowerCase() == folded) return country;
    }
    for (final country in _allCountriesSorted) {
      if (foldDiacritics(country.name).toLowerCase() == folded) return country;
    }
    return null;
  }

  /// Search countries by name, ISO code, or dial code
  /// Returns a record with filtered popular and all countries lists
  static ({List<Country> popular, List<Country> all}) searchSectioned(
    String query,
  ) {
    if (query.isEmpty) {
      return (popular: popularCountries, all: allCountries);
    }

    final foldedQuery = foldDiacritics(query);
    final lowerQuery = query.toLowerCase();
    final dialQuery = query.replaceAll('+', '');

    bool matches(Country country) {
      return foldDiacritics(country.name).contains(foldedQuery) ||
          country.isoCode.toLowerCase().startsWith(lowerQuery) ||
          country.dialCode.replaceAll('+', '').startsWith(dialQuery);
    }

    return (
      popular: popularCountries.where(matches).toList(),
      all: allCountries.where(matches).toList(),
    );
  }

  /// Search all countries (flat list for backwards compatibility)
  static List<Country> search(String query) {
    if (query.isEmpty) return countries;

    final foldedQuery = foldDiacritics(query);
    final lowerQuery = query.toLowerCase();
    final dialQuery = query.replaceAll('+', '');

    return countries.where((country) {
      return foldDiacritics(country.name).contains(foldedQuery) ||
          country.isoCode.toLowerCase().startsWith(lowerQuery) ||
          country.dialCode.replaceAll('+', '').startsWith(dialQuery);
    }).toList();
  }

  /// Popular countries shown at the top of the picker
  static const List<Country> popularCountries = [
    Country(
      name: 'Brazil',
      isoCode: 'BR',
      dialCode: '+55',
      flag: '\u{1F1E7}\u{1F1F7}',
    ),
    Country(
      name: 'Mexico',
      isoCode: 'MX',
      dialCode: '+52',
      flag: '\u{1F1F2}\u{1F1FD}',
    ),
    Country(
      name: 'Portugal',
      isoCode: 'PT',
      dialCode: '+351',
      flag: '\u{1F1F5}\u{1F1F9}',
    ),
    Country(
      name: 'Spain',
      isoCode: 'ES',
      dialCode: '+34',
      flag: '\u{1F1EA}\u{1F1F8}',
    ),
    Country(
      name: 'United Kingdom',
      isoCode: 'GB',
      dialCode: '+44',
      flag: '\u{1F1EC}\u{1F1E7}',
    ),
    Country(
      name: 'United States',
      isoCode: 'US',
      dialCode: '+1',
      flag: '\u{1F1FA}\u{1F1F8}',
    ),
  ];

  /// ISO codes of popular countries (for filtering)
  static final Set<String> _popularIsoCodes = popularCountries
      .map((c) => c.isoCode)
      .toSet();

  /// All countries alphabetically (excludes popular countries)
  static List<Country> get allCountries => _allCountriesSorted
      .where((c) => !_popularIsoCodes.contains(c.isoCode))
      .toList();

  /// Full list of countries (popular first, then alphabetically)
  static List<Country> get countries => [...popularCountries, ...allCountries];

  /// All countries sorted alphabetically (internal list)
  static const List<Country> _allCountriesSorted = [
    Country(
      name: 'Afghanistan',
      isoCode: 'AF',
      dialCode: '+93',
      flag: '\u{1F1E6}\u{1F1EB}',
    ),
    Country(
      name: 'Albania',
      isoCode: 'AL',
      dialCode: '+355',
      flag: '\u{1F1E6}\u{1F1F1}',
    ),
    Country(
      name: 'Algeria',
      isoCode: 'DZ',
      dialCode: '+213',
      flag: '\u{1F1E9}\u{1F1FF}',
    ),
    Country(
      name: 'American Samoa',
      isoCode: 'AS',
      dialCode: '+1684',
      flag: '\u{1F1E6}\u{1F1F8}',
    ),
    Country(
      name: 'Andorra',
      isoCode: 'AD',
      dialCode: '+376',
      flag: '\u{1F1E6}\u{1F1E9}',
    ),
    Country(
      name: 'Angola',
      isoCode: 'AO',
      dialCode: '+244',
      flag: '\u{1F1E6}\u{1F1F4}',
    ),
    Country(
      name: 'Anguilla',
      isoCode: 'AI',
      dialCode: '+1264',
      flag: '\u{1F1E6}\u{1F1EE}',
    ),
    Country(
      name: 'Antigua and Barbuda',
      isoCode: 'AG',
      dialCode: '+1268',
      flag: '\u{1F1E6}\u{1F1EC}',
    ),
    Country(
      name: 'Argentina',
      isoCode: 'AR',
      dialCode: '+54',
      flag: '\u{1F1E6}\u{1F1F7}',
    ),
    Country(
      name: 'Armenia',
      isoCode: 'AM',
      dialCode: '+374',
      flag: '\u{1F1E6}\u{1F1F2}',
    ),
    Country(
      name: 'Aruba',
      isoCode: 'AW',
      dialCode: '+297',
      flag: '\u{1F1E6}\u{1F1FC}',
    ),
    Country(
      name: 'Australia',
      isoCode: 'AU',
      dialCode: '+61',
      flag: '\u{1F1E6}\u{1F1FA}',
    ),
    Country(
      name: 'Austria',
      isoCode: 'AT',
      dialCode: '+43',
      flag: '\u{1F1E6}\u{1F1F9}',
    ),
    Country(
      name: 'Azerbaijan',
      isoCode: 'AZ',
      dialCode: '+994',
      flag: '\u{1F1E6}\u{1F1FF}',
    ),
    Country(
      name: 'Bahamas',
      isoCode: 'BS',
      dialCode: '+1242',
      flag: '\u{1F1E7}\u{1F1F8}',
    ),
    Country(
      name: 'Bahrain',
      isoCode: 'BH',
      dialCode: '+973',
      flag: '\u{1F1E7}\u{1F1ED}',
    ),
    Country(
      name: 'Bangladesh',
      isoCode: 'BD',
      dialCode: '+880',
      flag: '\u{1F1E7}\u{1F1E9}',
    ),
    Country(
      name: 'Barbados',
      isoCode: 'BB',
      dialCode: '+1246',
      flag: '\u{1F1E7}\u{1F1E7}',
    ),
    Country(
      name: 'Belarus',
      isoCode: 'BY',
      dialCode: '+375',
      flag: '\u{1F1E7}\u{1F1FE}',
    ),
    Country(
      name: 'Belgium',
      isoCode: 'BE',
      dialCode: '+32',
      flag: '\u{1F1E7}\u{1F1EA}',
    ),
    Country(
      name: 'Belize',
      isoCode: 'BZ',
      dialCode: '+501',
      flag: '\u{1F1E7}\u{1F1FF}',
    ),
    Country(
      name: 'Benin',
      isoCode: 'BJ',
      dialCode: '+229',
      flag: '\u{1F1E7}\u{1F1EF}',
    ),
    Country(
      name: 'Bermuda',
      isoCode: 'BM',
      dialCode: '+1441',
      flag: '\u{1F1E7}\u{1F1F2}',
    ),
    Country(
      name: 'Bhutan',
      isoCode: 'BT',
      dialCode: '+975',
      flag: '\u{1F1E7}\u{1F1F9}',
    ),
    Country(
      name: 'Bolivia',
      isoCode: 'BO',
      dialCode: '+591',
      flag: '\u{1F1E7}\u{1F1F4}',
    ),
    Country(
      name: 'Bosnia and Herzegovina',
      isoCode: 'BA',
      dialCode: '+387',
      flag: '\u{1F1E7}\u{1F1E6}',
    ),
    Country(
      name: 'Botswana',
      isoCode: 'BW',
      dialCode: '+267',
      flag: '\u{1F1E7}\u{1F1FC}',
    ),
    Country(
      name: 'British Virgin Islands',
      isoCode: 'VG',
      dialCode: '+1284',
      flag: '\u{1F1FB}\u{1F1EC}',
    ),
    Country(
      name: 'Brunei',
      isoCode: 'BN',
      dialCode: '+673',
      flag: '\u{1F1E7}\u{1F1F3}',
    ),
    Country(
      name: 'Bulgaria',
      isoCode: 'BG',
      dialCode: '+359',
      flag: '\u{1F1E7}\u{1F1EC}',
    ),
    Country(
      name: 'Burkina Faso',
      isoCode: 'BF',
      dialCode: '+226',
      flag: '\u{1F1E7}\u{1F1EB}',
    ),
    Country(
      name: 'Burundi',
      isoCode: 'BI',
      dialCode: '+257',
      flag: '\u{1F1E7}\u{1F1EE}',
    ),
    Country(
      name: 'Cambodia',
      isoCode: 'KH',
      dialCode: '+855',
      flag: '\u{1F1F0}\u{1F1ED}',
    ),
    Country(
      name: 'Cameroon',
      isoCode: 'CM',
      dialCode: '+237',
      flag: '\u{1F1E8}\u{1F1F2}',
    ),
    Country(
      name: 'Canada',
      isoCode: 'CA',
      dialCode: '+1',
      flag: '\u{1F1E8}\u{1F1E6}',
    ),
    Country(
      name: 'Cape Verde',
      isoCode: 'CV',
      dialCode: '+238',
      flag: '\u{1F1E8}\u{1F1FB}',
    ),
    Country(
      name: 'Cayman Islands',
      isoCode: 'KY',
      dialCode: '+1345',
      flag: '\u{1F1F0}\u{1F1FE}',
    ),
    Country(
      name: 'Central African Republic',
      isoCode: 'CF',
      dialCode: '+236',
      flag: '\u{1F1E8}\u{1F1EB}',
    ),
    Country(
      name: 'Chad',
      isoCode: 'TD',
      dialCode: '+235',
      flag: '\u{1F1F9}\u{1F1E9}',
    ),
    Country(
      name: 'Chile',
      isoCode: 'CL',
      dialCode: '+56',
      flag: '\u{1F1E8}\u{1F1F1}',
    ),
    Country(
      name: 'China',
      isoCode: 'CN',
      dialCode: '+86',
      flag: '\u{1F1E8}\u{1F1F3}',
    ),
    Country(
      name: 'Colombia',
      isoCode: 'CO',
      dialCode: '+57',
      flag: '\u{1F1E8}\u{1F1F4}',
    ),
    Country(
      name: 'Comoros',
      isoCode: 'KM',
      dialCode: '+269',
      flag: '\u{1F1F0}\u{1F1F2}',
    ),
    Country(
      name: 'Congo (DRC)',
      isoCode: 'CD',
      dialCode: '+243',
      flag: '\u{1F1E8}\u{1F1E9}',
    ),
    Country(
      name: 'Congo (Republic)',
      isoCode: 'CG',
      dialCode: '+242',
      flag: '\u{1F1E8}\u{1F1EC}',
    ),
    Country(
      name: 'Costa Rica',
      isoCode: 'CR',
      dialCode: '+506',
      flag: '\u{1F1E8}\u{1F1F7}',
    ),
    Country(
      name: 'Croatia',
      isoCode: 'HR',
      dialCode: '+385',
      flag: '\u{1F1ED}\u{1F1F7}',
    ),
    Country(
      name: 'Cuba',
      isoCode: 'CU',
      dialCode: '+53',
      flag: '\u{1F1E8}\u{1F1FA}',
    ),
    Country(
      name: 'Cyprus',
      isoCode: 'CY',
      dialCode: '+357',
      flag: '\u{1F1E8}\u{1F1FE}',
    ),
    Country(
      name: 'Czech Republic',
      isoCode: 'CZ',
      dialCode: '+420',
      flag: '\u{1F1E8}\u{1F1FF}',
    ),
    Country(
      name: 'Denmark',
      isoCode: 'DK',
      dialCode: '+45',
      flag: '\u{1F1E9}\u{1F1F0}',
    ),
    Country(
      name: 'Djibouti',
      isoCode: 'DJ',
      dialCode: '+253',
      flag: '\u{1F1E9}\u{1F1EF}',
    ),
    Country(
      name: 'Dominica',
      isoCode: 'DM',
      dialCode: '+1767',
      flag: '\u{1F1E9}\u{1F1F2}',
    ),
    Country(
      name: 'Dominican Republic',
      isoCode: 'DO',
      dialCode: '+1809',
      flag: '\u{1F1E9}\u{1F1F4}',
    ),
    Country(
      name: 'Ecuador',
      isoCode: 'EC',
      dialCode: '+593',
      flag: '\u{1F1EA}\u{1F1E8}',
    ),
    Country(
      name: 'Egypt',
      isoCode: 'EG',
      dialCode: '+20',
      flag: '\u{1F1EA}\u{1F1EC}',
    ),
    Country(
      name: 'El Salvador',
      isoCode: 'SV',
      dialCode: '+503',
      flag: '\u{1F1F8}\u{1F1FB}',
    ),
    Country(
      name: 'Equatorial Guinea',
      isoCode: 'GQ',
      dialCode: '+240',
      flag: '\u{1F1EC}\u{1F1F6}',
    ),
    Country(
      name: 'Eritrea',
      isoCode: 'ER',
      dialCode: '+291',
      flag: '\u{1F1EA}\u{1F1F7}',
    ),
    Country(
      name: 'Estonia',
      isoCode: 'EE',
      dialCode: '+372',
      flag: '\u{1F1EA}\u{1F1EA}',
    ),
    Country(
      name: 'Eswatini',
      isoCode: 'SZ',
      dialCode: '+268',
      flag: '\u{1F1F8}\u{1F1FF}',
    ),
    Country(
      name: 'Ethiopia',
      isoCode: 'ET',
      dialCode: '+251',
      flag: '\u{1F1EA}\u{1F1F9}',
    ),
    Country(
      name: 'Fiji',
      isoCode: 'FJ',
      dialCode: '+679',
      flag: '\u{1F1EB}\u{1F1EF}',
    ),
    Country(
      name: 'Finland',
      isoCode: 'FI',
      dialCode: '+358',
      flag: '\u{1F1EB}\u{1F1EE}',
    ),
    Country(
      name: 'France',
      isoCode: 'FR',
      dialCode: '+33',
      flag: '\u{1F1EB}\u{1F1F7}',
    ),
    Country(
      name: 'French Guiana',
      isoCode: 'GF',
      dialCode: '+594',
      flag: '\u{1F1EC}\u{1F1EB}',
    ),
    Country(
      name: 'French Polynesia',
      isoCode: 'PF',
      dialCode: '+689',
      flag: '\u{1F1F5}\u{1F1EB}',
    ),
    Country(
      name: 'Gabon',
      isoCode: 'GA',
      dialCode: '+241',
      flag: '\u{1F1EC}\u{1F1E6}',
    ),
    Country(
      name: 'Gambia',
      isoCode: 'GM',
      dialCode: '+220',
      flag: '\u{1F1EC}\u{1F1F2}',
    ),
    Country(
      name: 'Georgia',
      isoCode: 'GE',
      dialCode: '+995',
      flag: '\u{1F1EC}\u{1F1EA}',
    ),
    Country(
      name: 'Germany',
      isoCode: 'DE',
      dialCode: '+49',
      flag: '\u{1F1E9}\u{1F1EA}',
    ),
    Country(
      name: 'Ghana',
      isoCode: 'GH',
      dialCode: '+233',
      flag: '\u{1F1EC}\u{1F1ED}',
    ),
    Country(
      name: 'Gibraltar',
      isoCode: 'GI',
      dialCode: '+350',
      flag: '\u{1F1EC}\u{1F1EE}',
    ),
    Country(
      name: 'Greece',
      isoCode: 'GR',
      dialCode: '+30',
      flag: '\u{1F1EC}\u{1F1F7}',
    ),
    Country(
      name: 'Greenland',
      isoCode: 'GL',
      dialCode: '+299',
      flag: '\u{1F1EC}\u{1F1F1}',
    ),
    Country(
      name: 'Grenada',
      isoCode: 'GD',
      dialCode: '+1473',
      flag: '\u{1F1EC}\u{1F1E9}',
    ),
    Country(
      name: 'Guadeloupe',
      isoCode: 'GP',
      dialCode: '+590',
      flag: '\u{1F1EC}\u{1F1F5}',
    ),
    Country(
      name: 'Guam',
      isoCode: 'GU',
      dialCode: '+1671',
      flag: '\u{1F1EC}\u{1F1FA}',
    ),
    Country(
      name: 'Guatemala',
      isoCode: 'GT',
      dialCode: '+502',
      flag: '\u{1F1EC}\u{1F1F9}',
    ),
    Country(
      name: 'Guinea',
      isoCode: 'GN',
      dialCode: '+224',
      flag: '\u{1F1EC}\u{1F1F3}',
    ),
    Country(
      name: 'Guinea-Bissau',
      isoCode: 'GW',
      dialCode: '+245',
      flag: '\u{1F1EC}\u{1F1FC}',
    ),
    Country(
      name: 'Guyana',
      isoCode: 'GY',
      dialCode: '+592',
      flag: '\u{1F1EC}\u{1F1FE}',
    ),
    Country(
      name: 'Haiti',
      isoCode: 'HT',
      dialCode: '+509',
      flag: '\u{1F1ED}\u{1F1F9}',
    ),
    Country(
      name: 'Honduras',
      isoCode: 'HN',
      dialCode: '+504',
      flag: '\u{1F1ED}\u{1F1F3}',
    ),
    Country(
      name: 'Hong Kong',
      isoCode: 'HK',
      dialCode: '+852',
      flag: '\u{1F1ED}\u{1F1F0}',
    ),
    Country(
      name: 'Hungary',
      isoCode: 'HU',
      dialCode: '+36',
      flag: '\u{1F1ED}\u{1F1FA}',
    ),
    Country(
      name: 'Iceland',
      isoCode: 'IS',
      dialCode: '+354',
      flag: '\u{1F1EE}\u{1F1F8}',
    ),
    Country(
      name: 'India',
      isoCode: 'IN',
      dialCode: '+91',
      flag: '\u{1F1EE}\u{1F1F3}',
    ),
    Country(
      name: 'Indonesia',
      isoCode: 'ID',
      dialCode: '+62',
      flag: '\u{1F1EE}\u{1F1E9}',
    ),
    Country(
      name: 'Iran',
      isoCode: 'IR',
      dialCode: '+98',
      flag: '\u{1F1EE}\u{1F1F7}',
    ),
    Country(
      name: 'Iraq',
      isoCode: 'IQ',
      dialCode: '+964',
      flag: '\u{1F1EE}\u{1F1F6}',
    ),
    Country(
      name: 'Ireland',
      isoCode: 'IE',
      dialCode: '+353',
      flag: '\u{1F1EE}\u{1F1EA}',
    ),
    Country(
      name: 'Israel',
      isoCode: 'IL',
      dialCode: '+972',
      flag: '\u{1F1EE}\u{1F1F1}',
    ),
    Country(
      name: 'Italy',
      isoCode: 'IT',
      dialCode: '+39',
      flag: '\u{1F1EE}\u{1F1F9}',
    ),
    Country(
      name: 'Ivory Coast',
      isoCode: 'CI',
      dialCode: '+225',
      flag: '\u{1F1E8}\u{1F1EE}',
    ),
    Country(
      name: 'Jamaica',
      isoCode: 'JM',
      dialCode: '+1876',
      flag: '\u{1F1EF}\u{1F1F2}',
    ),
    Country(
      name: 'Japan',
      isoCode: 'JP',
      dialCode: '+81',
      flag: '\u{1F1EF}\u{1F1F5}',
    ),
    Country(
      name: 'Jordan',
      isoCode: 'JO',
      dialCode: '+962',
      flag: '\u{1F1EF}\u{1F1F4}',
    ),
    Country(
      name: 'Kazakhstan',
      isoCode: 'KZ',
      dialCode: '+7',
      flag: '\u{1F1F0}\u{1F1FF}',
    ),
    Country(
      name: 'Kenya',
      isoCode: 'KE',
      dialCode: '+254',
      flag: '\u{1F1F0}\u{1F1EA}',
    ),
    Country(
      name: 'Kiribati',
      isoCode: 'KI',
      dialCode: '+686',
      flag: '\u{1F1F0}\u{1F1EE}',
    ),
    Country(
      name: 'Kosovo',
      isoCode: 'XK',
      dialCode: '+383',
      flag: '\u{1F1FD}\u{1F1F0}',
    ),
    Country(
      name: 'Kuwait',
      isoCode: 'KW',
      dialCode: '+965',
      flag: '\u{1F1F0}\u{1F1FC}',
    ),
    Country(
      name: 'Kyrgyzstan',
      isoCode: 'KG',
      dialCode: '+996',
      flag: '\u{1F1F0}\u{1F1EC}',
    ),
    Country(
      name: 'Laos',
      isoCode: 'LA',
      dialCode: '+856',
      flag: '\u{1F1F1}\u{1F1E6}',
    ),
    Country(
      name: 'Latvia',
      isoCode: 'LV',
      dialCode: '+371',
      flag: '\u{1F1F1}\u{1F1FB}',
    ),
    Country(
      name: 'Lebanon',
      isoCode: 'LB',
      dialCode: '+961',
      flag: '\u{1F1F1}\u{1F1E7}',
    ),
    Country(
      name: 'Lesotho',
      isoCode: 'LS',
      dialCode: '+266',
      flag: '\u{1F1F1}\u{1F1F8}',
    ),
    Country(
      name: 'Liberia',
      isoCode: 'LR',
      dialCode: '+231',
      flag: '\u{1F1F1}\u{1F1F7}',
    ),
    Country(
      name: 'Libya',
      isoCode: 'LY',
      dialCode: '+218',
      flag: '\u{1F1F1}\u{1F1FE}',
    ),
    Country(
      name: 'Liechtenstein',
      isoCode: 'LI',
      dialCode: '+423',
      flag: '\u{1F1F1}\u{1F1EE}',
    ),
    Country(
      name: 'Lithuania',
      isoCode: 'LT',
      dialCode: '+370',
      flag: '\u{1F1F1}\u{1F1F9}',
    ),
    Country(
      name: 'Luxembourg',
      isoCode: 'LU',
      dialCode: '+352',
      flag: '\u{1F1F1}\u{1F1FA}',
    ),
    Country(
      name: 'Macau',
      isoCode: 'MO',
      dialCode: '+853',
      flag: '\u{1F1F2}\u{1F1F4}',
    ),
    Country(
      name: 'Madagascar',
      isoCode: 'MG',
      dialCode: '+261',
      flag: '\u{1F1F2}\u{1F1EC}',
    ),
    Country(
      name: 'Malawi',
      isoCode: 'MW',
      dialCode: '+265',
      flag: '\u{1F1F2}\u{1F1FC}',
    ),
    Country(
      name: 'Malaysia',
      isoCode: 'MY',
      dialCode: '+60',
      flag: '\u{1F1F2}\u{1F1FE}',
    ),
    Country(
      name: 'Maldives',
      isoCode: 'MV',
      dialCode: '+960',
      flag: '\u{1F1F2}\u{1F1FB}',
    ),
    Country(
      name: 'Mali',
      isoCode: 'ML',
      dialCode: '+223',
      flag: '\u{1F1F2}\u{1F1F1}',
    ),
    Country(
      name: 'Malta',
      isoCode: 'MT',
      dialCode: '+356',
      flag: '\u{1F1F2}\u{1F1F9}',
    ),
    Country(
      name: 'Marshall Islands',
      isoCode: 'MH',
      dialCode: '+692',
      flag: '\u{1F1F2}\u{1F1ED}',
    ),
    Country(
      name: 'Martinique',
      isoCode: 'MQ',
      dialCode: '+596',
      flag: '\u{1F1F2}\u{1F1F6}',
    ),
    Country(
      name: 'Mauritania',
      isoCode: 'MR',
      dialCode: '+222',
      flag: '\u{1F1F2}\u{1F1F7}',
    ),
    Country(
      name: 'Mauritius',
      isoCode: 'MU',
      dialCode: '+230',
      flag: '\u{1F1F2}\u{1F1FA}',
    ),
    Country(
      name: 'Mexico',
      isoCode: 'MX',
      dialCode: '+52',
      flag: '\u{1F1F2}\u{1F1FD}',
    ),
    Country(
      name: 'Micronesia',
      isoCode: 'FM',
      dialCode: '+691',
      flag: '\u{1F1EB}\u{1F1F2}',
    ),
    Country(
      name: 'Moldova',
      isoCode: 'MD',
      dialCode: '+373',
      flag: '\u{1F1F2}\u{1F1E9}',
    ),
    Country(
      name: 'Monaco',
      isoCode: 'MC',
      dialCode: '+377',
      flag: '\u{1F1F2}\u{1F1E8}',
    ),
    Country(
      name: 'Mongolia',
      isoCode: 'MN',
      dialCode: '+976',
      flag: '\u{1F1F2}\u{1F1F3}',
    ),
    Country(
      name: 'Montenegro',
      isoCode: 'ME',
      dialCode: '+382',
      flag: '\u{1F1F2}\u{1F1EA}',
    ),
    Country(
      name: 'Montserrat',
      isoCode: 'MS',
      dialCode: '+1664',
      flag: '\u{1F1F2}\u{1F1F8}',
    ),
    Country(
      name: 'Morocco',
      isoCode: 'MA',
      dialCode: '+212',
      flag: '\u{1F1F2}\u{1F1E6}',
    ),
    Country(
      name: 'Mozambique',
      isoCode: 'MZ',
      dialCode: '+258',
      flag: '\u{1F1F2}\u{1F1FF}',
    ),
    Country(
      name: 'Myanmar',
      isoCode: 'MM',
      dialCode: '+95',
      flag: '\u{1F1F2}\u{1F1F2}',
    ),
    Country(
      name: 'Namibia',
      isoCode: 'NA',
      dialCode: '+264',
      flag: '\u{1F1F3}\u{1F1E6}',
    ),
    Country(
      name: 'Nauru',
      isoCode: 'NR',
      dialCode: '+674',
      flag: '\u{1F1F3}\u{1F1F7}',
    ),
    Country(
      name: 'Nepal',
      isoCode: 'NP',
      dialCode: '+977',
      flag: '\u{1F1F3}\u{1F1F5}',
    ),
    Country(
      name: 'Netherlands',
      isoCode: 'NL',
      dialCode: '+31',
      flag: '\u{1F1F3}\u{1F1F1}',
    ),
    Country(
      name: 'New Caledonia',
      isoCode: 'NC',
      dialCode: '+687',
      flag: '\u{1F1F3}\u{1F1E8}',
    ),
    Country(
      name: 'New Zealand',
      isoCode: 'NZ',
      dialCode: '+64',
      flag: '\u{1F1F3}\u{1F1FF}',
    ),
    Country(
      name: 'Nicaragua',
      isoCode: 'NI',
      dialCode: '+505',
      flag: '\u{1F1F3}\u{1F1EE}',
    ),
    Country(
      name: 'Niger',
      isoCode: 'NE',
      dialCode: '+227',
      flag: '\u{1F1F3}\u{1F1EA}',
    ),
    Country(
      name: 'Nigeria',
      isoCode: 'NG',
      dialCode: '+234',
      flag: '\u{1F1F3}\u{1F1EC}',
    ),
    Country(
      name: 'North Korea',
      isoCode: 'KP',
      dialCode: '+850',
      flag: '\u{1F1F0}\u{1F1F5}',
    ),
    Country(
      name: 'North Macedonia',
      isoCode: 'MK',
      dialCode: '+389',
      flag: '\u{1F1F2}\u{1F1F0}',
    ),
    Country(
      name: 'Norway',
      isoCode: 'NO',
      dialCode: '+47',
      flag: '\u{1F1F3}\u{1F1F4}',
    ),
    Country(
      name: 'Oman',
      isoCode: 'OM',
      dialCode: '+968',
      flag: '\u{1F1F4}\u{1F1F2}',
    ),
    Country(
      name: 'Pakistan',
      isoCode: 'PK',
      dialCode: '+92',
      flag: '\u{1F1F5}\u{1F1F0}',
    ),
    Country(
      name: 'Palau',
      isoCode: 'PW',
      dialCode: '+680',
      flag: '\u{1F1F5}\u{1F1FC}',
    ),
    Country(
      name: 'Palestine',
      isoCode: 'PS',
      dialCode: '+970',
      flag: '\u{1F1F5}\u{1F1F8}',
    ),
    Country(
      name: 'Panama',
      isoCode: 'PA',
      dialCode: '+507',
      flag: '\u{1F1F5}\u{1F1E6}',
    ),
    Country(
      name: 'Papua New Guinea',
      isoCode: 'PG',
      dialCode: '+675',
      flag: '\u{1F1F5}\u{1F1EC}',
    ),
    Country(
      name: 'Paraguay',
      isoCode: 'PY',
      dialCode: '+595',
      flag: '\u{1F1F5}\u{1F1FE}',
    ),
    Country(
      name: 'Peru',
      isoCode: 'PE',
      dialCode: '+51',
      flag: '\u{1F1F5}\u{1F1EA}',
    ),
    Country(
      name: 'Philippines',
      isoCode: 'PH',
      dialCode: '+63',
      flag: '\u{1F1F5}\u{1F1ED}',
    ),
    Country(
      name: 'Poland',
      isoCode: 'PL',
      dialCode: '+48',
      flag: '\u{1F1F5}\u{1F1F1}',
    ),
    Country(
      name: 'Puerto Rico',
      isoCode: 'PR',
      dialCode: '+1787',
      flag: '\u{1F1F5}\u{1F1F7}',
    ),
    Country(
      name: 'Qatar',
      isoCode: 'QA',
      dialCode: '+974',
      flag: '\u{1F1F6}\u{1F1E6}',
    ),
    Country(
      name: 'Reunion',
      isoCode: 'RE',
      dialCode: '+262',
      flag: '\u{1F1F7}\u{1F1EA}',
    ),
    Country(
      name: 'Romania',
      isoCode: 'RO',
      dialCode: '+40',
      flag: '\u{1F1F7}\u{1F1F4}',
    ),
    Country(
      name: 'Russia',
      isoCode: 'RU',
      dialCode: '+7',
      flag: '\u{1F1F7}\u{1F1FA}',
    ),
    Country(
      name: 'Rwanda',
      isoCode: 'RW',
      dialCode: '+250',
      flag: '\u{1F1F7}\u{1F1FC}',
    ),
    Country(
      name: 'Saint Kitts and Nevis',
      isoCode: 'KN',
      dialCode: '+1869',
      flag: '\u{1F1F0}\u{1F1F3}',
    ),
    Country(
      name: 'Saint Lucia',
      isoCode: 'LC',
      dialCode: '+1758',
      flag: '\u{1F1F1}\u{1F1E8}',
    ),
    Country(
      name: 'Saint Vincent and the Grenadines',
      isoCode: 'VC',
      dialCode: '+1784',
      flag: '\u{1F1FB}\u{1F1E8}',
    ),
    Country(
      name: 'Samoa',
      isoCode: 'WS',
      dialCode: '+685',
      flag: '\u{1F1FC}\u{1F1F8}',
    ),
    Country(
      name: 'San Marino',
      isoCode: 'SM',
      dialCode: '+378',
      flag: '\u{1F1F8}\u{1F1F2}',
    ),
    Country(
      name: 'Sao Tome and Principe',
      isoCode: 'ST',
      dialCode: '+239',
      flag: '\u{1F1F8}\u{1F1F9}',
    ),
    Country(
      name: 'Saudi Arabia',
      isoCode: 'SA',
      dialCode: '+966',
      flag: '\u{1F1F8}\u{1F1E6}',
    ),
    Country(
      name: 'Senegal',
      isoCode: 'SN',
      dialCode: '+221',
      flag: '\u{1F1F8}\u{1F1F3}',
    ),
    Country(
      name: 'Serbia',
      isoCode: 'RS',
      dialCode: '+381',
      flag: '\u{1F1F7}\u{1F1F8}',
    ),
    Country(
      name: 'Seychelles',
      isoCode: 'SC',
      dialCode: '+248',
      flag: '\u{1F1F8}\u{1F1E8}',
    ),
    Country(
      name: 'Sierra Leone',
      isoCode: 'SL',
      dialCode: '+232',
      flag: '\u{1F1F8}\u{1F1F1}',
    ),
    Country(
      name: 'Singapore',
      isoCode: 'SG',
      dialCode: '+65',
      flag: '\u{1F1F8}\u{1F1EC}',
    ),
    Country(
      name: 'Slovakia',
      isoCode: 'SK',
      dialCode: '+421',
      flag: '\u{1F1F8}\u{1F1F0}',
    ),
    Country(
      name: 'Slovenia',
      isoCode: 'SI',
      dialCode: '+386',
      flag: '\u{1F1F8}\u{1F1EE}',
    ),
    Country(
      name: 'Solomon Islands',
      isoCode: 'SB',
      dialCode: '+677',
      flag: '\u{1F1F8}\u{1F1E7}',
    ),
    Country(
      name: 'Somalia',
      isoCode: 'SO',
      dialCode: '+252',
      flag: '\u{1F1F8}\u{1F1F4}',
    ),
    Country(
      name: 'South Africa',
      isoCode: 'ZA',
      dialCode: '+27',
      flag: '\u{1F1FF}\u{1F1E6}',
    ),
    Country(
      name: 'South Korea',
      isoCode: 'KR',
      dialCode: '+82',
      flag: '\u{1F1F0}\u{1F1F7}',
    ),
    Country(
      name: 'South Sudan',
      isoCode: 'SS',
      dialCode: '+211',
      flag: '\u{1F1F8}\u{1F1F8}',
    ),
    Country(
      name: 'Sri Lanka',
      isoCode: 'LK',
      dialCode: '+94',
      flag: '\u{1F1F1}\u{1F1F0}',
    ),
    Country(
      name: 'Sudan',
      isoCode: 'SD',
      dialCode: '+249',
      flag: '\u{1F1F8}\u{1F1E9}',
    ),
    Country(
      name: 'Suriname',
      isoCode: 'SR',
      dialCode: '+597',
      flag: '\u{1F1F8}\u{1F1F7}',
    ),
    Country(
      name: 'Sweden',
      isoCode: 'SE',
      dialCode: '+46',
      flag: '\u{1F1F8}\u{1F1EA}',
    ),
    Country(
      name: 'Switzerland',
      isoCode: 'CH',
      dialCode: '+41',
      flag: '\u{1F1E8}\u{1F1ED}',
    ),
    Country(
      name: 'Syria',
      isoCode: 'SY',
      dialCode: '+963',
      flag: '\u{1F1F8}\u{1F1FE}',
    ),
    Country(
      name: 'Taiwan',
      isoCode: 'TW',
      dialCode: '+886',
      flag: '\u{1F1F9}\u{1F1FC}',
    ),
    Country(
      name: 'Tajikistan',
      isoCode: 'TJ',
      dialCode: '+992',
      flag: '\u{1F1F9}\u{1F1EF}',
    ),
    Country(
      name: 'Tanzania',
      isoCode: 'TZ',
      dialCode: '+255',
      flag: '\u{1F1F9}\u{1F1FF}',
    ),
    Country(
      name: 'Thailand',
      isoCode: 'TH',
      dialCode: '+66',
      flag: '\u{1F1F9}\u{1F1ED}',
    ),
    Country(
      name: 'Timor-Leste',
      isoCode: 'TL',
      dialCode: '+670',
      flag: '\u{1F1F9}\u{1F1F1}',
    ),
    Country(
      name: 'Togo',
      isoCode: 'TG',
      dialCode: '+228',
      flag: '\u{1F1F9}\u{1F1EC}',
    ),
    Country(
      name: 'Tonga',
      isoCode: 'TO',
      dialCode: '+676',
      flag: '\u{1F1F9}\u{1F1F4}',
    ),
    Country(
      name: 'Trinidad and Tobago',
      isoCode: 'TT',
      dialCode: '+1868',
      flag: '\u{1F1F9}\u{1F1F9}',
    ),
    Country(
      name: 'Tunisia',
      isoCode: 'TN',
      dialCode: '+216',
      flag: '\u{1F1F9}\u{1F1F3}',
    ),
    Country(
      name: 'Turkey',
      isoCode: 'TR',
      dialCode: '+90',
      flag: '\u{1F1F9}\u{1F1F7}',
    ),
    Country(
      name: 'Turkmenistan',
      isoCode: 'TM',
      dialCode: '+993',
      flag: '\u{1F1F9}\u{1F1F2}',
    ),
    Country(
      name: 'Turks and Caicos Islands',
      isoCode: 'TC',
      dialCode: '+1649',
      flag: '\u{1F1F9}\u{1F1E8}',
    ),
    Country(
      name: 'Tuvalu',
      isoCode: 'TV',
      dialCode: '+688',
      flag: '\u{1F1F9}\u{1F1FB}',
    ),
    Country(
      name: 'Uganda',
      isoCode: 'UG',
      dialCode: '+256',
      flag: '\u{1F1FA}\u{1F1EC}',
    ),
    Country(
      name: 'Ukraine',
      isoCode: 'UA',
      dialCode: '+380',
      flag: '\u{1F1FA}\u{1F1E6}',
    ),
    Country(
      name: 'United Arab Emirates',
      isoCode: 'AE',
      dialCode: '+971',
      flag: '\u{1F1E6}\u{1F1EA}',
    ),
    Country(
      name: 'Uruguay',
      isoCode: 'UY',
      dialCode: '+598',
      flag: '\u{1F1FA}\u{1F1FE}',
    ),
    Country(
      name: 'Uzbekistan',
      isoCode: 'UZ',
      dialCode: '+998',
      flag: '\u{1F1FA}\u{1F1FF}',
    ),
    Country(
      name: 'Vanuatu',
      isoCode: 'VU',
      dialCode: '+678',
      flag: '\u{1F1FB}\u{1F1FA}',
    ),
    Country(
      name: 'Vatican City',
      isoCode: 'VA',
      dialCode: '+379',
      flag: '\u{1F1FB}\u{1F1E6}',
    ),
    Country(
      name: 'Venezuela',
      isoCode: 'VE',
      dialCode: '+58',
      flag: '\u{1F1FB}\u{1F1EA}',
    ),
    Country(
      name: 'Vietnam',
      isoCode: 'VN',
      dialCode: '+84',
      flag: '\u{1F1FB}\u{1F1F3}',
    ),
    Country(
      name: 'Yemen',
      isoCode: 'YE',
      dialCode: '+967',
      flag: '\u{1F1FE}\u{1F1EA}',
    ),
    Country(
      name: 'Zambia',
      isoCode: 'ZM',
      dialCode: '+260',
      flag: '\u{1F1FF}\u{1F1F2}',
    ),
    Country(
      name: 'Zimbabwe',
      isoCode: 'ZW',
      dialCode: '+263',
      flag: '\u{1F1FF}\u{1F1FC}',
    ),
  ];
}
