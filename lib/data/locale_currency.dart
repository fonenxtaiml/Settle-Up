// Home currency suggested from the device locale (onboarding preselects
// it). Owner: data.
//
// Pure lookup: region subtag (ISO 3166-1 alpha-2) -> ISO 4217 code, with a
// few language-only fallbacks. Anything unknown gives [kFallbackHomeCurrency].
import '../core/money.dart';

const String kFallbackHomeCurrency = 'USD';

/// Currency for a locale name such as `en_IN`, `en-IN`, `hi_IN.UTF-8`,
/// `sr_Latn_RS` or `de_DE@euro`. Returns [kFallbackHomeCurrency] when the
/// locale is null, has no known region, or maps to a code missing from
/// [Currencies].
String homeCurrencyForLocale(String? locale) {
  if (locale == null) return kFallbackHomeCurrency;
  var name = locale.trim();
  for (final sep in const ['.', '@']) {
    final i = name.indexOf(sep);
    if (i >= 0) name = name.substring(0, i);
  }
  final parts = name.split(RegExp('[-_]')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return kFallbackHomeCurrency;
  String? code;
  for (final part in parts.skip(1)) {
    if (part.length == 2) code = _byRegion[part.toUpperCase()];
    if (code != null) break;
  }
  code ??= parts.length == 1 ? _byLanguage[parts.first.toLowerCase()] : null;
  if (code == null || Currencies.tryOf(code) == null) {
    return kFallbackHomeCurrency;
  }
  return code;
}

/// Languages that point at one currency when the locale carries no region.
const Map<String, String> _byLanguage = {
  'cs': 'CZK', 'da': 'DKK', 'he': 'ILS', 'hi': 'INR', 'hu': 'HUF',
  'id': 'IDR', 'is': 'ISK', 'ja': 'JPY', 'ka': 'GEL', 'ko': 'KRW',
  'nb': 'NOK', 'nn': 'NOK', 'no': 'NOK', 'pl': 'PLN', 'ro': 'RON',
  'sv': 'SEK', 'th': 'THB', 'tr': 'TRY', 'uk': 'UAH', 'vi': 'VND',
};

/// ISO 3166-1 alpha-2 -> circulating ISO 4217 currency.
const Map<String, String> _byRegion = {
  // Euro area and territories using the euro.
  'AD': 'EUR', 'AT': 'EUR', 'AX': 'EUR', 'BE': 'EUR', 'BL': 'EUR',
  'CY': 'EUR', 'DE': 'EUR', 'EE': 'EUR', 'ES': 'EUR', 'FI': 'EUR',
  'FR': 'EUR', 'GF': 'EUR', 'GP': 'EUR', 'GR': 'EUR', 'HR': 'EUR',
  'IE': 'EUR', 'IT': 'EUR', 'LT': 'EUR', 'LU': 'EUR', 'LV': 'EUR',
  'MC': 'EUR', 'ME': 'EUR', 'MF': 'EUR', 'MQ': 'EUR', 'MT': 'EUR',
  'NL': 'EUR', 'PM': 'EUR', 'PT': 'EUR', 'RE': 'EUR', 'SI': 'EUR',
  'SK': 'EUR', 'SM': 'EUR', 'TF': 'EUR', 'VA': 'EUR', 'XK': 'EUR',
  'YT': 'EUR', 'BG': 'EUR',
  // US dollar.
  'AS': 'USD', 'BQ': 'USD', 'EC': 'USD', 'FM': 'USD', 'GU': 'USD',
  'IO': 'USD', 'MH': 'USD', 'MP': 'USD', 'PR': 'USD', 'PW': 'USD',
  'SV': 'USD', 'TC': 'USD', 'TL': 'USD', 'UM': 'USD', 'US': 'USD',
  'VG': 'USD', 'VI': 'USD',
  // East Caribbean dollar.
  'AG': 'XCD', 'AI': 'XCD', 'DM': 'XCD', 'GD': 'XCD', 'KN': 'XCD',
  'LC': 'XCD', 'MS': 'XCD', 'VC': 'XCD',
  // Caribbean guilder.
  'CW': 'XCG', 'SX': 'XCG',
  // CFA francs and CFP franc.
  'BF': 'XOF', 'BJ': 'XOF', 'CI': 'XOF', 'GW': 'XOF', 'ML': 'XOF',
  'NE': 'XOF', 'SN': 'XOF', 'TG': 'XOF',
  'CF': 'XAF', 'CG': 'XAF', 'CM': 'XAF', 'GA': 'XAF', 'GQ': 'XAF',
  'TD': 'XAF',
  'NC': 'XPF', 'PF': 'XPF', 'WF': 'XPF',
  // Shared currencies of other unions and dependencies.
  'AU': 'AUD', 'CC': 'AUD', 'CX': 'AUD', 'HM': 'AUD', 'KI': 'AUD',
  'NF': 'AUD', 'NR': 'AUD', 'TV': 'AUD',
  'NZ': 'NZD', 'CK': 'NZD', 'NU': 'NZD', 'PN': 'NZD', 'TK': 'NZD',
  'GB': 'GBP', 'GG': 'GBP', 'IM': 'GBP', 'JE': 'GBP', 'GS': 'GBP',
  'CH': 'CHF', 'LI': 'CHF',
  'DK': 'DKK', 'FO': 'DKK', 'GL': 'DKK',
  'NO': 'NOK', 'SJ': 'NOK', 'BV': 'NOK',
  'MA': 'MAD', 'EH': 'MAD',
  'IL': 'ILS', 'PS': 'ILS',
  'SH': 'SHP',
  // One currency each.
  'AE': 'AED', 'AF': 'AFN', 'AL': 'ALL', 'AM': 'AMD', 'AO': 'AOA',
  'AR': 'ARS', 'AW': 'AWG', 'AZ': 'AZN', 'BA': 'BAM', 'BB': 'BBD',
  'BD': 'BDT', 'BH': 'BHD', 'BI': 'BIF', 'BM': 'BMD', 'BN': 'BND',
  'BO': 'BOB', 'BR': 'BRL', 'BS': 'BSD', 'BT': 'BTN', 'BW': 'BWP',
  'BY': 'BYN', 'BZ': 'BZD', 'CA': 'CAD', 'CD': 'CDF', 'CL': 'CLP',
  'CN': 'CNY', 'CO': 'COP', 'CR': 'CRC', 'CU': 'CUP', 'CV': 'CVE',
  'CZ': 'CZK', 'DJ': 'DJF', 'DO': 'DOP', 'DZ': 'DZD', 'EG': 'EGP',
  'ER': 'ERN', 'ET': 'ETB', 'FJ': 'FJD', 'FK': 'FKP', 'GE': 'GEL',
  'GH': 'GHS', 'GI': 'GIP', 'GM': 'GMD', 'GN': 'GNF', 'GT': 'GTQ',
  'GY': 'GYD', 'HK': 'HKD', 'HN': 'HNL', 'HT': 'HTG', 'HU': 'HUF',
  'ID': 'IDR', 'IN': 'INR', 'IQ': 'IQD', 'IR': 'IRR', 'IS': 'ISK',
  'JM': 'JMD', 'JO': 'JOD', 'JP': 'JPY', 'KE': 'KES', 'KG': 'KGS',
  'KH': 'KHR', 'KM': 'KMF', 'KP': 'KPW', 'KR': 'KRW', 'KW': 'KWD',
  'KY': 'KYD', 'KZ': 'KZT', 'LA': 'LAK', 'LB': 'LBP', 'LK': 'LKR',
  'LR': 'LRD', 'LS': 'LSL', 'LY': 'LYD', 'MD': 'MDL', 'MG': 'MGA',
  'MK': 'MKD', 'MM': 'MMK', 'MN': 'MNT', 'MO': 'MOP', 'MR': 'MRU',
  'MU': 'MUR', 'MV': 'MVR', 'MW': 'MWK', 'MX': 'MXN', 'MY': 'MYR',
  'MZ': 'MZN', 'NA': 'NAD', 'NG': 'NGN', 'NI': 'NIO', 'NP': 'NPR',
  'OM': 'OMR', 'PA': 'PAB', 'PE': 'PEN', 'PG': 'PGK', 'PH': 'PHP',
  'PK': 'PKR', 'PL': 'PLN', 'PY': 'PYG', 'QA': 'QAR', 'RO': 'RON',
  'RS': 'RSD', 'RU': 'RUB', 'RW': 'RWF', 'SA': 'SAR', 'SB': 'SBD',
  'SC': 'SCR', 'SD': 'SDG', 'SE': 'SEK', 'SG': 'SGD', 'SL': 'SLE',
  'SO': 'SOS', 'SR': 'SRD', 'SS': 'SSP', 'ST': 'STN', 'SY': 'SYP',
  'SZ': 'SZL', 'TH': 'THB', 'TJ': 'TJS', 'TM': 'TMT', 'TN': 'TND',
  'TO': 'TOP', 'TR': 'TRY', 'TT': 'TTD', 'TW': 'TWD', 'TZ': 'TZS',
  'UA': 'UAH', 'UG': 'UGX', 'UY': 'UYU', 'UZ': 'UZS', 'VE': 'VES',
  'VN': 'VND', 'VU': 'VUV', 'WS': 'WST', 'YE': 'YER', 'ZA': 'ZAR',
  'ZM': 'ZMW', 'ZW': 'ZWG',
};
