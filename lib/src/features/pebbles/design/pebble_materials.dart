import 'package:zen/src/app/i18n/zen_i18n.dart';

/// How a stone's surface takes the light, and what its bare surface looks
/// like under the paint.
enum PebbleFinish {
  /// Matte paint: soft light, almost no shine.
  matte(ambient: 0.42, diffuse: 0.7, specular: 0.08, shininess: 8),

  /// Gloss varnish: a sharp white highlight.
  gloss(ambient: 0.38, diffuse: 0.72, specular: 0.75, shininess: 48),

  /// Granite: speckled, a little shine.
  granite(ambient: 0.4, diffuse: 0.72, specular: 0.18, shininess: 14),

  /// Sea glass: frosted, bright at the rim as if lit from inside.
  seaGlass(
    ambient: 0.55,
    diffuse: 0.5,
    specular: 0.35,
    shininess: 20,
    rim: 0.45,
    rimTint: 1,
  ),

  /// Metallic marker: a tinted highlight and a reflected horizon.
  metallic(
    ambient: 0.3,
    diffuse: 0.6,
    specular: 0.9,
    shininess: 28,
    specTint: 0.85,
    env: 0.35,
  ),

  /// Marble: veins, a soft polish.
  marble(ambient: 0.45, diffuse: 0.62, specular: 0.4, shininess: 30),

  /// A river stone: mottled, with quartz bands.
  river(ambient: 0.4, diffuse: 0.72, specular: 0.14, shininess: 10);

  const PebbleFinish({
    required this.ambient,
    required this.diffuse,
    required this.specular,
    required this.shininess,
    this.specTint = 0,
    this.rim = 0,
    this.rimTint = 0,
    this.env = 0,
  });

  final double ambient;
  final double diffuse;
  final double specular;
  final double shininess;

  /// 0: white highlights, 1: highlights in the stone's colour.
  final double specTint;

  /// Light at the rim (sea glass) and how much of it takes the colour.
  final double rim;
  final double rimTint;

  /// A bright band reflected from the horizon (metal).
  final double env;
}

/// The base materials and colours of a stone. The index is stored in
/// designs and cards: add new ones at the end only.
enum PebbleMaterial {
  greyGranite(PebbleFinish.granite, 0xFF8E8E8A, 0xFF3A3A38),
  pinkGranite(PebbleFinish.granite, 0xFFC9A39A, 0xFF5B3F3A),
  basalt(PebbleFinish.matte, 0xFF3C3E42, 0xFF6A6D72),
  sandstone(PebbleFinish.granite, 0xFFD8C29A, 0xFFA8875A),
  whiteMarble(PebbleFinish.marble, 0xFFF1EEE8, 0xFF9C9A96),
  greenMarble(PebbleFinish.marble, 0xFF3F6B57, 0xFFDCE8DF),
  greyRiver(PebbleFinish.river, 0xFF9A9C98, 0xFFF2F0EA),
  brownRiver(PebbleFinish.river, 0xFF8B6E55, 0xFFEDE3D3),
  blackRiver(PebbleFinish.river, 0xFF2E2F31, 0xFFE9E6DF),
  seaGlassGreen(PebbleFinish.seaGlass, 0xFF9CCFB0, 0xFFE6F6EC),
  seaGlassBlue(PebbleFinish.seaGlass, 0xFF8FC1DA, 0xFFE3F2FA),
  seaGlassAmber(PebbleFinish.seaGlass, 0xFFD9A85B, 0xFFFBEBCB),
  seaGlassWhite(PebbleFinish.seaGlass, 0xFFE4ECEA, 0xFFFFFFFF),
  glossRed(PebbleFinish.gloss, 0xFFD7263D, 0xFF7A0F1E),
  glossBlue(PebbleFinish.gloss, 0xFF1F5FBF, 0xFF0B2A5C),
  glossYellow(PebbleFinish.gloss, 0xFFF7C531, 0xFFB7860B),
  glossGreen(PebbleFinish.gloss, 0xFF2E9E5B, 0xFF135A30),
  glossBlack(PebbleFinish.gloss, 0xFF1B1C1F, 0xFF55585E),
  glossWhite(PebbleFinish.gloss, 0xFFF7F7F4, 0xFFBFC2C6),
  glossOrange(PebbleFinish.gloss, 0xFFF27A1A, 0xFF9A4206),
  glossPurple(PebbleFinish.gloss, 0xFF7B3FB5, 0xFF3D1A63),
  pastelPink(PebbleFinish.matte, 0xFFF4B6C8, 0xFFB5687F),
  pastelMint(PebbleFinish.matte, 0xFFB5E6CF, 0xFF5E9C80),
  pastelLavender(PebbleFinish.matte, 0xFFCDBDEB, 0xFF7C68A8),
  pastelPeach(PebbleFinish.matte, 0xFFF8CBA6, 0xFFB57B4C),
  pastelSky(PebbleFinish.matte, 0xFFB7D9F2, 0xFF5D8DB3),
  gold(PebbleFinish.metallic, 0xFFD4A93A, 0xFF7A5A10),
  silver(PebbleFinish.metallic, 0xFFC4C8CE, 0xFF6C7178),
  copper(PebbleFinish.metallic, 0xFFC27445, 0xFF6B3518),
  pearl(PebbleFinish.metallic, 0xFFEFE8E1, 0xFFC9B8C8),
  chalk(PebbleFinish.matte, 0xFFF3F1EA, 0xFFC8C4B8),
  charcoal(PebbleFinish.matte, 0xFF2B2B2B, 0xFF5A5A5A),
  terracotta(PebbleFinish.matte, 0xFFC0603E, 0xFF7C3520),
  jade(PebbleFinish.marble, 0xFF5FA884, 0xFF2F6B4E),
  obsidian(PebbleFinish.gloss, 0xFF141418, 0xFF3E3A52),
  roseQuartz(PebbleFinish.seaGlass, 0xFFF0C2CF, 0xFFFFEEF3),
  lava(PebbleFinish.granite, 0xFF4A3B38, 0xFFB5482A),
  nightSky(PebbleFinish.gloss, 0xFF141B3D, 0xFF3B4C9B),
  slate(PebbleFinish.matte, 0xFF56616B, 0xFF8C99A5),
  sand(PebbleFinish.granite, 0xFFE9D9B8, 0xFFB79F72);

  const PebbleMaterial(this.finish, this.main, this.second);

  final PebbleFinish finish;

  /// The stone's colour and its second colour (speckles, veins, bands), as
  /// 0xAARRGGBB.
  final int main;
  final int second;

  static PebbleMaterial byId(int id) =>
      id >= 0 && id < values.length ? values[id] : greyRiver;

  String get label => switch (this) {
    greyGranite => t('Szary granit'),
    pinkGranite => t('Różowy granit'),
    basalt => t('Bazalt'),
    sandstone => t('Piaskowiec'),
    whiteMarble => t('Biały marmur'),
    greenMarble => t('Zielony marmur'),
    greyRiver => t('Szary z rzeki'),
    brownRiver => t('Brązowy z rzeki'),
    blackRiver => t('Czarny z rzeki'),
    seaGlassGreen => t('Zielone szkło morskie'),
    seaGlassBlue => t('Niebieskie szkło morskie'),
    seaGlassAmber => t('Bursztynowe szkło morskie'),
    seaGlassWhite => t('Mleczne szkło morskie'),
    glossRed => t('Czerwony lakier'),
    glossBlue => t('Niebieski lakier'),
    glossYellow => t('Żółty lakier'),
    glossGreen => t('Zielony lakier'),
    glossBlack => t('Czarny lakier'),
    glossWhite => t('Biały lakier'),
    glossOrange => t('Pomarańczowy lakier'),
    glossPurple => t('Fioletowy lakier'),
    pastelPink => t('Pastelowy róż'),
    pastelMint => t('Pastelowa mięta'),
    pastelLavender => t('Pastelowa lawenda'),
    pastelPeach => t('Pastelowa brzoskwinia'),
    pastelSky => t('Pastelowy błękit'),
    gold => t('Złoty marker'),
    silver => t('Srebrny marker'),
    copper => t('Miedziany marker'),
    pearl => t('Perłowy'),
    chalk => t('Kreda'),
    charcoal => t('Węgiel'),
    terracotta => t('Terakota'),
    jade => t('Jadeit'),
    obsidian => t('Obsydian'),
    roseQuartz => t('Kwarc różowy'),
    lava => t('Lawa'),
    nightSky => t('Nocne niebo'),
    slate => t('Łupek'),
    sand => t('Piasek'),
  };
}

/// The colours the paint tools offer (0xAARRGGBB), light to dark per hue.
const List<int> pebblePaintColours = <int>[
  0xFFFFFFFF,
  0xFFF3EEE3,
  0xFFBDBDBD,
  0xFF6B6B6B,
  0xFF1A1A1A,
  0xFFFFD6DE,
  0xFFFF7A9C,
  0xFFE5243B,
  0xFF9E1328,
  0xFFFFB27A,
  0xFFFF7F11,
  0xFFC05A0A,
  0xFFFFF09A,
  0xFFFFD21F,
  0xFFC99A00,
  0xFFC9F29B,
  0xFF6BCB3B,
  0xFF2E8B3E,
  0xFF145A2A,
  0xFFA6F0E6,
  0xFF1FB5A8,
  0xFF0E6E6A,
  0xFFAED8FF,
  0xFF3E8EEA,
  0xFF1846A8,
  0xFF0B1F5C,
  0xFFDCC6FF,
  0xFF9B5DE5,
  0xFF5B2A9E,
  0xFF8B5A33,
  0xFF5A3A20,
  0xFFD4A93A,
  0xFFC4C8CE,
];

/// What a screen reader says for a colour of [pebblePaintColours] (any
/// other colour: its hex code).
String pebbleColourName(int argb) => switch (argb | 0xFF000000) {
  0xFFFFFFFF => t('biały'),
  0xFFF3EEE3 => t('kremowy'),
  0xFFBDBDBD => t('jasnoszary'),
  0xFF6B6B6B => t('ciemnoszary'),
  0xFF1A1A1A => t('czarny'),
  0xFFFFD6DE => t('bladoróżowy'),
  0xFFFF7A9C => t('różowy'),
  0xFFE5243B => t('czerwony'),
  0xFF9E1328 => t('bordowy'),
  0xFFFFB27A => t('brzoskwiniowy'),
  0xFFFF7F11 => t('pomarańczowy'),
  0xFFC05A0A => t('rdzawy'),
  0xFFFFF09A => t('jasnożółty'),
  0xFFFFD21F => t('żółty'),
  0xFFC99A00 => t('musztardowy'),
  0xFFC9F29B => t('jasnozielony'),
  0xFF6BCB3B => t('zielony'),
  0xFF2E8B3E => t('leśna zieleń'),
  0xFF145A2A => t('butelkowa zieleń'),
  0xFFA6F0E6 => t('miętowy'),
  0xFF1FB5A8 => t('turkusowy'),
  0xFF0E6E6A => t('morski'),
  0xFFAED8FF => t('błękitny'),
  0xFF3E8EEA => t('niebieski'),
  0xFF1846A8 => t('kobaltowy'),
  0xFF0B1F5C => t('granatowy'),
  0xFFDCC6FF => t('lawendowy'),
  0xFF9B5DE5 => t('fioletowy'),
  0xFF5B2A9E => t('śliwkowy'),
  0xFF8B5A33 => t('brązowy'),
  0xFF5A3A20 => t('ciemnobrązowy'),
  0xFFD4A93A => t('złoty'),
  0xFFC4C8CE => t('srebrny'),
  final int other =>
    '#${(other & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
};

/// Harmonious colour sets for "Losuj" and the patterns' second colours.
const List<List<int>> pebblePalettes = <List<int>>[
  <int>[0xFF264653, 0xFF2A9D8F, 0xFFE9C46A, 0xFFF4A261, 0xFFE76F51],
  <int>[0xFFFFBE0B, 0xFFFB5607, 0xFFFF006E, 0xFF8338EC, 0xFF3A86FF],
  <int>[0xFF003049, 0xFFD62828, 0xFFF77F00, 0xFFFCBF49, 0xFFEAE2B7],
  <int>[0xFF606C38, 0xFF283618, 0xFFFEFAE0, 0xFFDDA15E, 0xFFBC6C25],
  <int>[0xFFCDB4DB, 0xFFFFC8DD, 0xFFFFAFCC, 0xFFBDE0FE, 0xFFA2D2FF],
  <int>[0xFF0B132B, 0xFF1C2541, 0xFF3A506B, 0xFF5BC0BE, 0xFFFFFFFF],
  <int>[0xFFF72585, 0xFF7209B7, 0xFF3A0CA3, 0xFF4361EE, 0xFF4CC9F0],
  <int>[0xFF2B2D42, 0xFF8D99AE, 0xFFEDF2F4, 0xFFEF233C, 0xFFD90429],
  <int>[0xFF006D77, 0xFF83C5BE, 0xFFEDF6F9, 0xFFFFDDD2, 0xFFE29578],
  <int>[0xFF8ECAE6, 0xFF219EBC, 0xFF023047, 0xFFFFB703, 0xFFFB8500],
  <int>[0xFF588157, 0xFF3A5A40, 0xFFA3B18A, 0xFFDAD7CD, 0xFF344E41],
  <int>[0xFFFFCDB2, 0xFFFFB4A2, 0xFFE5989B, 0xFFB5838D, 0xFF6D6875],
  <int>[0xFF1A1A1A, 0xFFFFFFFF, 0xFFE5243B, 0xFFFFD21F, 0xFF3E8EEA],
  <int>[0xFF7F5539, 0xFFA68A64, 0xFFEDE0D4, 0xFF656D4A, 0xFF414833],
];
