// ISO 4217 active currency table (docs/SPEC.md section 5.2). Owner: core.
//
// Circulating currencies only: fund codes (BOV, CHE, CHW, CLF, COU, MXV,
// USN, UYI, UYW), precious metals, SDR and test codes are left out.
// Withdrawn codes (for example BGN, HRK, SLL, ANG, ZWL) are left out too;
// ops that still carry them keep working through `Currencies.of`, which
// falls back to 2 minor digits.
//
// Sorted by code. `minorDigits` follows the ISO 4217 list.
import 'money.dart';

const List<Currency> isoCurrencies = <Currency>[
  Currency(code: 'AED', minorDigits: 2, symbol: 'AED', name: 'UAE dirham'),
  Currency(code: 'AFN', minorDigits: 2, symbol: '؋', name: 'Afghan afghani'),
  Currency(code: 'ALL', minorDigits: 2, symbol: 'L', name: 'Albanian lek'),
  Currency(code: 'AMD', minorDigits: 2, symbol: '֏', name: 'Armenian dram'),
  Currency(code: 'AOA', minorDigits: 2, symbol: 'Kz', name: 'Angolan kwanza'),
  Currency(code: 'ARS', minorDigits: 2, symbol: r'$', name: 'Argentine peso'),
  Currency(
      code: 'AUD', minorDigits: 2, symbol: r'A$', name: 'Australian dollar'),
  Currency(code: 'AWG', minorDigits: 2, symbol: 'ƒ', name: 'Aruban florin'),
  Currency(
      code: 'AZN', minorDigits: 2, symbol: '₼', name: 'Azerbaijani manat'),
  Currency(
      code: 'BAM',
      minorDigits: 2,
      symbol: 'KM',
      name: 'Bosnia and Herzegovina convertible mark'),
  Currency(
      code: 'BBD', minorDigits: 2, symbol: r'Bds$', name: 'Barbadian dollar'),
  Currency(
      code: 'BDT', minorDigits: 2, symbol: '৳', name: 'Bangladeshi taka'),
  Currency(code: 'BHD', minorDigits: 3, symbol: 'BD', name: 'Bahraini dinar'),
  Currency(
      code: 'BIF', minorDigits: 0, symbol: 'FBu', name: 'Burundian franc'),
  Currency(
      code: 'BMD', minorDigits: 2, symbol: r'$', name: 'Bermudian dollar'),
  Currency(code: 'BND', minorDigits: 2, symbol: r'B$', name: 'Brunei dollar'),
  Currency(
      code: 'BOB', minorDigits: 2, symbol: 'Bs', name: 'Bolivian boliviano'),
  Currency(code: 'BRL', minorDigits: 2, symbol: r'R$', name: 'Brazilian real'),
  Currency(
      code: 'BSD', minorDigits: 2, symbol: r'B$', name: 'Bahamian dollar'),
  Currency(
      code: 'BTN', minorDigits: 2, symbol: 'Nu.', name: 'Bhutanese ngultrum'),
  Currency(code: 'BWP', minorDigits: 2, symbol: 'P', name: 'Botswana pula'),
  Currency(
      code: 'BYN', minorDigits: 2, symbol: 'Br', name: 'Belarusian ruble'),
  Currency(code: 'BZD', minorDigits: 2, symbol: r'BZ$', name: 'Belize dollar'),
  Currency(
      code: 'CAD', minorDigits: 2, symbol: r'CA$', name: 'Canadian dollar'),
  Currency(code: 'CDF', minorDigits: 2, symbol: 'FC', name: 'Congolese franc'),
  Currency(code: 'CHF', minorDigits: 2, symbol: 'CHF', name: 'Swiss franc'),
  Currency(code: 'CLP', minorDigits: 0, symbol: r'$', name: 'Chilean peso'),
  Currency(code: 'CNY', minorDigits: 2, symbol: 'CN¥', name: 'Chinese yuan'),
  Currency(code: 'COP', minorDigits: 2, symbol: r'$', name: 'Colombian peso'),
  Currency(
      code: 'CRC', minorDigits: 2, symbol: '₡', name: 'Costa Rican colón'),
  Currency(code: 'CUP', minorDigits: 2, symbol: r'$', name: 'Cuban peso'),
  Currency(
      code: 'CVE', minorDigits: 2, symbol: 'Esc', name: 'Cape Verdean escudo'),
  Currency(code: 'CZK', minorDigits: 2, symbol: 'Kč', name: 'Czech koruna'),
  Currency(
      code: 'DJF', minorDigits: 0, symbol: 'Fdj', name: 'Djiboutian franc'),
  Currency(code: 'DKK', minorDigits: 2, symbol: 'kr', name: 'Danish krone'),
  Currency(
      code: 'DOP', minorDigits: 2, symbol: r'RD$', name: 'Dominican peso'),
  Currency(code: 'DZD', minorDigits: 2, symbol: 'DA', name: 'Algerian dinar'),
  Currency(code: 'EGP', minorDigits: 2, symbol: 'E£', name: 'Egyptian pound'),
  Currency(code: 'ERN', minorDigits: 2, symbol: 'Nfk', name: 'Eritrean nakfa'),
  Currency(code: 'ETB', minorDigits: 2, symbol: 'Br', name: 'Ethiopian birr'),
  Currency(code: 'EUR', minorDigits: 2, symbol: '€', name: 'Euro'),
  Currency(code: 'FJD', minorDigits: 2, symbol: r'FJ$', name: 'Fijian dollar'),
  Currency(
      code: 'FKP',
      minorDigits: 2,
      symbol: '£',
      name: 'Falkland Islands pound'),
  Currency(code: 'GBP', minorDigits: 2, symbol: '£', name: 'British pound'),
  Currency(code: 'GEL', minorDigits: 2, symbol: '₾', name: 'Georgian lari'),
  Currency(code: 'GHS', minorDigits: 2, symbol: 'GH₵', name: 'Ghanaian cedi'),
  Currency(code: 'GIP', minorDigits: 2, symbol: '£', name: 'Gibraltar pound'),
  Currency(code: 'GMD', minorDigits: 2, symbol: 'D', name: 'Gambian dalasi'),
  Currency(code: 'GNF', minorDigits: 0, symbol: 'FG', name: 'Guinean franc'),
  Currency(
      code: 'GTQ', minorDigits: 2, symbol: 'Q', name: 'Guatemalan quetzal'),
  Currency(
      code: 'GYD', minorDigits: 2, symbol: r'G$', name: 'Guyanese dollar'),
  Currency(
      code: 'HKD', minorDigits: 2, symbol: r'HK$', name: 'Hong Kong dollar'),
  Currency(
      code: 'HNL', minorDigits: 2, symbol: 'L', name: 'Honduran lempira'),
  Currency(code: 'HTG', minorDigits: 2, symbol: 'G', name: 'Haitian gourde'),
  Currency(
      code: 'HUF', minorDigits: 2, symbol: 'Ft', name: 'Hungarian forint'),
  Currency(
      code: 'IDR', minorDigits: 2, symbol: 'Rp', name: 'Indonesian rupiah'),
  Currency(
      code: 'ILS', minorDigits: 2, symbol: '₪', name: 'Israeli new shekel'),
  Currency(code: 'INR', minorDigits: 2, symbol: '₹', name: 'Indian rupee'),
  Currency(code: 'IQD', minorDigits: 3, symbol: 'IQD', name: 'Iraqi dinar'),
  Currency(code: 'IRR', minorDigits: 2, symbol: 'IRR', name: 'Iranian rial'),
  Currency(
      code: 'ISK', minorDigits: 0, symbol: 'kr', name: 'Icelandic króna'),
  Currency(
      code: 'JMD', minorDigits: 2, symbol: r'J$', name: 'Jamaican dollar'),
  Currency(code: 'JOD', minorDigits: 3, symbol: 'JD', name: 'Jordanian dinar'),
  Currency(code: 'JPY', minorDigits: 0, symbol: '¥', name: 'Japanese yen'),
  Currency(
      code: 'KES', minorDigits: 2, symbol: 'KSh', name: 'Kenyan shilling'),
  Currency(
      code: 'KGS', minorDigits: 2, symbol: 'som', name: 'Kyrgyzstani som'),
  Currency(code: 'KHR', minorDigits: 2, symbol: '៛', name: 'Cambodian riel'),
  Currency(code: 'KMF', minorDigits: 0, symbol: 'CF', name: 'Comorian franc'),
  Currency(
      code: 'KPW', minorDigits: 2, symbol: '₩', name: 'North Korean won'),
  Currency(
      code: 'KRW', minorDigits: 0, symbol: '₩', name: 'South Korean won'),
  Currency(code: 'KWD', minorDigits: 3, symbol: 'KD', name: 'Kuwaiti dinar'),
  Currency(
      code: 'KYD',
      minorDigits: 2,
      symbol: r'CI$',
      name: 'Cayman Islands dollar'),
  Currency(
      code: 'KZT', minorDigits: 2, symbol: '₸', name: 'Kazakhstani tenge'),
  Currency(code: 'LAK', minorDigits: 2, symbol: '₭', name: 'Lao kip'),
  Currency(code: 'LBP', minorDigits: 2, symbol: 'L£', name: 'Lebanese pound'),
  Currency(
      code: 'LKR', minorDigits: 2, symbol: 'Rs', name: 'Sri Lankan rupee'),
  Currency(
      code: 'LRD', minorDigits: 2, symbol: r'L$', name: 'Liberian dollar'),
  Currency(code: 'LSL', minorDigits: 2, symbol: 'L', name: 'Lesotho loti'),
  Currency(code: 'LYD', minorDigits: 3, symbol: 'LD', name: 'Libyan dinar'),
  Currency(
      code: 'MAD', minorDigits: 2, symbol: 'MAD', name: 'Moroccan dirham'),
  Currency(code: 'MDL', minorDigits: 2, symbol: 'L', name: 'Moldovan leu'),
  Currency(
      code: 'MGA', minorDigits: 2, symbol: 'Ar', name: 'Malagasy ariary'),
  Currency(
      code: 'MKD', minorDigits: 2, symbol: 'den', name: 'Macedonian denar'),
  Currency(code: 'MMK', minorDigits: 2, symbol: 'K', name: 'Myanmar kyat'),
  Currency(
      code: 'MNT', minorDigits: 2, symbol: '₮', name: 'Mongolian tögrög'),
  Currency(
      code: 'MOP', minorDigits: 2, symbol: r'MOP$', name: 'Macanese pataca'),
  Currency(
      code: 'MRU', minorDigits: 2, symbol: 'UM', name: 'Mauritanian ouguiya'),
  Currency(
      code: 'MUR', minorDigits: 2, symbol: 'Rs', name: 'Mauritian rupee'),
  Currency(
      code: 'MVR', minorDigits: 2, symbol: 'Rf', name: 'Maldivian rufiyaa'),
  Currency(
      code: 'MWK', minorDigits: 2, symbol: 'MK', name: 'Malawian kwacha'),
  Currency(code: 'MXN', minorDigits: 2, symbol: r'MX$', name: 'Mexican peso'),
  Currency(
      code: 'MYR', minorDigits: 2, symbol: 'RM', name: 'Malaysian ringgit'),
  Currency(
      code: 'MZN', minorDigits: 2, symbol: 'MT', name: 'Mozambican metical'),
  Currency(
      code: 'NAD', minorDigits: 2, symbol: r'N$', name: 'Namibian dollar'),
  Currency(code: 'NGN', minorDigits: 2, symbol: '₦', name: 'Nigerian naira'),
  Currency(
      code: 'NIO', minorDigits: 2, symbol: r'C$', name: 'Nicaraguan córdoba'),
  Currency(code: 'NOK', minorDigits: 2, symbol: 'kr', name: 'Norwegian krone'),
  Currency(code: 'NPR', minorDigits: 2, symbol: 'Rs', name: 'Nepalese rupee'),
  Currency(
      code: 'NZD', minorDigits: 2, symbol: r'NZ$', name: 'New Zealand dollar'),
  Currency(code: 'OMR', minorDigits: 3, symbol: 'OMR', name: 'Omani rial'),
  Currency(
      code: 'PAB', minorDigits: 2, symbol: 'B/.', name: 'Panamanian balboa'),
  Currency(code: 'PEN', minorDigits: 2, symbol: 'S/', name: 'Peruvian sol'),
  Currency(
      code: 'PGK',
      minorDigits: 2,
      symbol: 'K',
      name: 'Papua New Guinean kina'),
  Currency(
      code: 'PHP', minorDigits: 2, symbol: '₱', name: 'Philippine peso'),
  Currency(
      code: 'PKR', minorDigits: 2, symbol: 'Rs', name: 'Pakistani rupee'),
  Currency(code: 'PLN', minorDigits: 2, symbol: 'zł', name: 'Polish złoty'),
  Currency(
      code: 'PYG', minorDigits: 0, symbol: '₲', name: 'Paraguayan guaraní'),
  Currency(code: 'QAR', minorDigits: 2, symbol: 'QR', name: 'Qatari riyal'),
  Currency(code: 'RON', minorDigits: 2, symbol: 'lei', name: 'Romanian leu'),
  Currency(code: 'RSD', minorDigits: 2, symbol: 'din', name: 'Serbian dinar'),
  Currency(code: 'RUB', minorDigits: 2, symbol: '₽', name: 'Russian ruble'),
  Currency(code: 'RWF', minorDigits: 0, symbol: 'FRw', name: 'Rwandan franc'),
  Currency(code: 'SAR', minorDigits: 2, symbol: 'SR', name: 'Saudi riyal'),
  Currency(
      code: 'SBD',
      minorDigits: 2,
      symbol: r'SI$',
      name: 'Solomon Islands dollar'),
  Currency(
      code: 'SCR', minorDigits: 2, symbol: 'SR', name: 'Seychellois rupee'),
  Currency(
      code: 'SDG', minorDigits: 2, symbol: 'SDG', name: 'Sudanese pound'),
  Currency(code: 'SEK', minorDigits: 2, symbol: 'kr', name: 'Swedish krona'),
  Currency(
      code: 'SGD', minorDigits: 2, symbol: r'S$', name: 'Singapore dollar'),
  Currency(
      code: 'SHP', minorDigits: 2, symbol: '£', name: 'Saint Helena pound'),
  Currency(
      code: 'SLE', minorDigits: 2, symbol: 'Le', name: 'Sierra Leonean leone'),
  Currency(
      code: 'SOS', minorDigits: 2, symbol: 'Sh.So.', name: 'Somali shilling'),
  Currency(
      code: 'SRD', minorDigits: 2, symbol: r'Sr$', name: 'Surinamese dollar'),
  Currency(
      code: 'SSP', minorDigits: 2, symbol: 'SS£', name: 'South Sudanese pound'),
  Currency(
      code: 'STN',
      minorDigits: 2,
      symbol: 'Db',
      name: 'São Tomé and Príncipe dobra'),
  Currency(
      code: 'SVC', minorDigits: 2, symbol: '₡', name: 'Salvadoran colón'),
  Currency(code: 'SYP', minorDigits: 2, symbol: 'S£', name: 'Syrian pound'),
  Currency(code: 'SZL', minorDigits: 2, symbol: 'E', name: 'Swazi lilangeni'),
  Currency(code: 'THB', minorDigits: 2, symbol: '฿', name: 'Thai baht'),
  Currency(
      code: 'TJS', minorDigits: 2, symbol: 'SM', name: 'Tajikistani somoni'),
  Currency(
      code: 'TMT', minorDigits: 2, symbol: 'm', name: 'Turkmenistan manat'),
  Currency(code: 'TND', minorDigits: 3, symbol: 'DT', name: 'Tunisian dinar'),
  Currency(code: 'TOP', minorDigits: 2, symbol: r'T$', name: 'Tongan paʻanga'),
  Currency(code: 'TRY', minorDigits: 2, symbol: '₺', name: 'Turkish lira'),
  Currency(
      code: 'TTD',
      minorDigits: 2,
      symbol: r'TT$',
      name: 'Trinidad and Tobago dollar'),
  Currency(
      code: 'TWD', minorDigits: 2, symbol: r'NT$', name: 'New Taiwan dollar'),
  Currency(
      code: 'TZS', minorDigits: 2, symbol: 'TSh', name: 'Tanzanian shilling'),
  Currency(
      code: 'UAH', minorDigits: 2, symbol: '₴', name: 'Ukrainian hryvnia'),
  Currency(
      code: 'UGX', minorDigits: 0, symbol: 'USh', name: 'Ugandan shilling'),
  Currency(code: 'USD', minorDigits: 2, symbol: r'$', name: 'US dollar'),
  Currency(
      code: 'UYU', minorDigits: 2, symbol: r'$U', name: 'Uruguayan peso'),
  Currency(
      code: 'UZS', minorDigits: 2, symbol: 'soʻm', name: 'Uzbekistani som'),
  Currency(
      code: 'VED',
      minorDigits: 2,
      symbol: 'Bs.D',
      name: 'Venezuelan digital bolívar'),
  Currency(
      code: 'VES',
      minorDigits: 2,
      symbol: 'Bs.S',
      name: 'Venezuelan sovereign bolívar'),
  Currency(
      code: 'VND', minorDigits: 0, symbol: '₫', name: 'Vietnamese đồng'),
  Currency(code: 'VUV', minorDigits: 0, symbol: 'VT', name: 'Vanuatu vatu'),
  Currency(code: 'WST', minorDigits: 2, symbol: r'WS$', name: 'Samoan tālā'),
  Currency(
      code: 'XAF',
      minorDigits: 0,
      symbol: 'FCFA',
      name: 'Central African CFA franc'),
  Currency(
      code: 'XCD',
      minorDigits: 2,
      symbol: r'EC$',
      name: 'East Caribbean dollar'),
  Currency(
      code: 'XCG', minorDigits: 2, symbol: 'Cg', name: 'Caribbean guilder'),
  Currency(
      code: 'XOF',
      minorDigits: 0,
      symbol: 'CFA',
      name: 'West African CFA franc'),
  Currency(code: 'XPF', minorDigits: 0, symbol: 'F', name: 'CFP franc'),
  Currency(code: 'YER', minorDigits: 2, symbol: 'YR', name: 'Yemeni rial'),
  Currency(
      code: 'ZAR', minorDigits: 2, symbol: 'R', name: 'South African rand'),
  Currency(
      code: 'ZMW', minorDigits: 2, symbol: 'ZK', name: 'Zambian kwacha'),
  Currency(code: 'ZWG', minorDigits: 2, symbol: 'ZiG', name: 'Zimbabwe gold'),
];
