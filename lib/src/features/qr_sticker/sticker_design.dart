import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

/// What a sticker's QR code opens: each kind keeps its own last design and
/// offers its own ready texts.
enum StickerKind {
  /// "Mój kod": the person's invitation.
  friendInvite,

  /// The flat's door code (Sąsiedzi).
  door,

  /// The install page.
  installPage,

  /// The author's collection.
  donation,

  /// The page about Zen (the promotional sticker in "O aplikacji").
  zenAbout;

  /// The file name the exports start with.
  String get fileStem => switch (this) {
    StickerKind.friendInvite => 'zen-zaproszenie',
    StickerKind.door => 'zen-naklejka-na-drzwi',
    StickerKind.installPage => 'zen-instalacja',
    StickerKind.donation => 'zen-wsparcie',
    StickerKind.zenAbout => 'zen-naklejka',
  };
}

/// How the QR code's modules are drawn. The finder eyes, the timing lines
/// and the alignment marks stay whole in every style, the modules keep
/// their centres dark, and the code stays dark on light: cameras read all
/// of them (test/qr_sticker_test.dart decodes each one).
enum QrStyle {
  classic,
  rounded,
  dots,
  softEyes;

  String get label => switch (this) {
    QrStyle.classic => t('Klasyczny'),
    QrStyle.rounded => t('Zaokrąglony'),
    QrStyle.dots => t('Kropki'),
    QrStyle.softEyes => t('Okrągłe oczka'),
  };
}

/// The sticker's colours: [ink] for the code and the texts, always dark on
/// the white of the code and on [paper] ([QrMatrix.minContrast] or more);
/// [accent] and [accentSoft] only for the patterns around.
enum StickerTheme {
  classic(0xFFFFFFFF, 0xFF111114, 0xFF8E8E96, 0xFFC8C8CE),
  ocean(0xFFF1F6FC, 0xFF0B2E59, 0xFF4A8FD9, 0xFF9CC6EF),
  forest(0xFFF2F8F0, 0xFF143D24, 0xFF59A15C, 0xFFA8D29A),
  berry(0xFFFBF1F6, 0xFF4A1342, 0xFFCF559A, 0xFFF0A7CE),
  sunset(0xFFFFF5EC, 0xFF5C1A0B, 0xFFEE8636, 0xFFF6C169),
  violet(0xFFF5F2FC, 0xFF2D1B69, 0xFF8A6EE0, 0xFFC5B6F3);

  const StickerTheme(this.paper, this.ink, this.accent, this.accentSoft);

  final int paper;
  final int ink;
  final int accent;
  final int accentSoft;

  /// Behind the code and its quiet zone: always white.
  static const int plate = 0xFFFFFFFF;

  String get label => switch (this) {
    StickerTheme.classic => t('Czarno na białym'),
    StickerTheme.ocean => t('Ocean'),
    StickerTheme.forest => t('Las'),
    StickerTheme.berry => t('Jagoda'),
    StickerTheme.sunset => t('Zachód słońca'),
    StickerTheme.violet => t('Fiolet'),
  };
}

/// Little drawings around the code, only in the margins.
enum StickerPattern {
  none,
  butterflies,
  leaves,
  confetti,
  stars,
  hearts,
  waves;

  String get label => switch (this) {
    StickerPattern.none => t('Bez wzorku'),
    StickerPattern.butterflies => t('Motyle'),
    StickerPattern.leaves => t('Liście'),
    StickerPattern.confetti => t('Konfetti'),
    StickerPattern.stars => t('Gwiazdki'),
    StickerPattern.hearts => t('Serca'),
    StickerPattern.waves => t('Fale'),
  };
}

/// The page the square artwork is printed on, centred, so it can be cut
/// out as a square.
enum StickerPage {
  a4(210, 297),
  a5(148, 210),
  letter(215.9, 279.4),
  square(200, 200),
  sticker(100, 100),

  /// A phone wallpaper: 1080 × 2340 pixels (taken at 300 dpi for a PDF).
  wallpaper(1080 / 300 * 25.4, 2340 / 300 * 25.4);

  const StickerPage(this.widthMm, this.heightMm);

  /// Portrait size.
  final double widthMm;
  final double heightMm;

  /// The square formats have no orientation.
  bool get hasOrientation => widthMm != heightMm;

  /// Paper with margins, where cutting lines make sense.
  bool get hasMargins =>
      this == StickerPage.a4 ||
      this == StickerPage.a5 ||
      this == StickerPage.letter;

  String get label => switch (this) {
    StickerPage.a4 => 'A4',
    StickerPage.a5 => 'A5',
    StickerPage.letter => 'Letter',
    StickerPage.square => t('Kwadrat 20 × 20 cm'),
    StickerPage.sticker => t('Naklejka 10 × 10 cm'),
    StickerPage.wallpaper => t('Tapeta na telefon'),
  };
}

/// The file the sticker is saved as.
enum StickerFormat {
  pdf('pdf', 'application/pdf'),
  png('png', 'image/png'),
  jpg('jpg', 'image/jpeg'),
  svg('svg', 'image/svg+xml');

  const StickerFormat(this.extension, this.mime);

  final String extension;
  final String mime;

  String get label => extension.toUpperCase();
}

/// The texts of a sticker: above the code, a small line right under it,
/// and below.
@immutable
final class StickerTexts {
  const StickerTexts({this.top = '', this.caption = '', this.bottom = ''});

  final String top;
  final String caption;
  final String bottom;

  @override
  bool operator ==(Object other) =>
      other is StickerTexts &&
      other.top == top &&
      other.caption == caption &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(top, caption, bottom);
}

/// Everything the person chose for one kind of sticker (kept per kind,
/// [StickerStore]).
@immutable
final class StickerDesign {
  const StickerDesign({
    this.texts = const StickerTexts(),
    this.signature = true,
    this.style = QrStyle.classic,
    this.theme = StickerTheme.classic,
    this.pattern = StickerPattern.none,
    this.logo = false,
    this.page = StickerPage.a4,
    this.landscape = false,
    this.cropMarks = true,
    this.format = StickerFormat.pdf,
  });

  /// The design a kind starts with: its first ready texts for [name].
  factory StickerDesign.initial(StickerKind kind, {String name = ''}) =>
      StickerDesign(texts: stickerPresets(kind, name: name).first);

  /// Longest text above or below the code.
  static const int maxText = 80;

  /// Longest line under the code.
  static const int maxCaption = 60;

  final StickerTexts texts;

  /// The small "Zen" mark in the corner.
  final bool signature;
  final QrStyle style;
  final StickerTheme theme;
  final StickerPattern pattern;

  /// Zen's logo in the middle of the code (only where the code can carry
  /// it, [QrMatrix.logoHole]).
  final bool logo;
  final StickerPage page;
  final bool landscape;
  final bool cropMarks;
  final StickerFormat format;

  StickerDesign copyWith({
    StickerTexts? texts,
    bool? signature,
    QrStyle? style,
    StickerTheme? theme,
    StickerPattern? pattern,
    bool? logo,
    StickerPage? page,
    bool? landscape,
    bool? cropMarks,
    StickerFormat? format,
  }) => StickerDesign(
    texts: texts ?? this.texts,
    signature: signature ?? this.signature,
    style: style ?? this.style,
    theme: theme ?? this.theme,
    pattern: pattern ?? this.pattern,
    logo: logo ?? this.logo,
    page: page ?? this.page,
    landscape: landscape ?? this.landscape,
    cropMarks: cropMarks ?? this.cropMarks,
    format: format ?? this.format,
  );

  Map<String, Object> toJson() => <String, Object>{
    'top': texts.top,
    'caption': texts.caption,
    'bottom': texts.bottom,
    'signature': signature,
    'style': style.name,
    'theme': theme.name,
    'pattern': pattern.name,
    'logo': logo,
    'page': page.name,
    'landscape': landscape,
    'cropMarks': cropMarks,
    'format': format.name,
  };

  /// Named fields: an unknown one is ignored and a missing one keeps its
  /// default.
  static StickerDesign fromJson(Map<Object?, Object?> json) {
    String text(String key, int max) {
      final Object? value = json[key];
      if (value is! String) {
        return '';
      }
      return value.length > max ? value.substring(0, max) : value;
    }

    bool flag(String key, bool fallback) {
      final Object? value = json[key];
      return value is bool ? value : fallback;
    }

    E pick<E extends Enum>(List<E> values, String key, E fallback) {
      final Object? name = json[key];
      for (final E value in values) {
        if (value.name == name) {
          return value;
        }
      }
      return fallback;
    }

    const StickerDesign d = StickerDesign();
    return StickerDesign(
      texts: StickerTexts(
        top: text('top', maxText),
        caption: text('caption', maxCaption),
        bottom: text('bottom', maxText),
      ),
      signature: flag('signature', d.signature),
      style: pick(QrStyle.values, 'style', d.style),
      theme: pick(StickerTheme.values, 'theme', d.theme),
      pattern: pick(StickerPattern.values, 'pattern', d.pattern),
      logo: flag('logo', d.logo),
      page: pick(StickerPage.values, 'page', d.page),
      landscape: flag('landscape', d.landscape),
      cropMarks: flag('cropMarks', d.cropMarks),
      format: pick(StickerFormat.values, 'format', d.format),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StickerDesign &&
      other.texts == texts &&
      other.signature == signature &&
      other.style == style &&
      other.theme == theme &&
      other.pattern == pattern &&
      other.logo == logo &&
      other.page == page &&
      other.landscape == landscape &&
      other.cropMarks == cropMarks &&
      other.format == format;

  @override
  int get hashCode => Object.hash(
    texts,
    signature,
    style,
    theme,
    pattern,
    logo,
    page,
    landscape,
    cropMarks,
    format,
  );
}

/// The ready texts of [kind] for the person's or the flat's [name]; a text
/// that needs a name is left out while there is none.
List<StickerTexts> stickerPresets(StickerKind kind, {String name = ''}) {
  final String who = name.trim();
  final bool named = who.isNotEmpty;
  return switch (kind) {
    StickerKind.friendInvite => <StickerTexts>[
      if (named) StickerTexts(top: who, bottom: t('Dodaj mnie w Zen')),
      StickerTexts(bottom: t('Zeskanuj, żeby dodać mnie do znajomych')),
      StickerTexts(
        top: t('Dołącz do mnie w Zen'),
        bottom: t('Prywatna sieć społecznościowa — zeskanuj'),
      ),
      StickerTexts(top: t('Dodaj mnie w Zen')),
    ],
    StickerKind.door => <StickerTexts>[
      if (named) StickerTexts(top: who, bottom: t('Zeskanuj, żeby nas poznać')),
      if (named)
        StickerTexts(
          bottom: t('{name} — zeskanuj QR, aby nas poznać', <String, Object?>{
            'name': who,
          }),
        ),
      if (named)
        StickerTexts(top: who, bottom: t('Zeskanuj — zapraszamy na kawę!')),
      StickerTexts(
        top: t('Sąsiedzi'),
        bottom: t('Zapukaj do nas przez Zen — zeskanuj'),
      ),
      StickerTexts(bottom: t('Zeskanuj, żeby nas poznać')),
    ],
    StickerKind.installPage => <StickerTexts>[
      StickerTexts(top: 'Zen', bottom: t('Zeskanuj i zainstaluj Zen')),
      StickerTexts(bottom: t('Prywatna sieć społecznościowa — zeskanuj')),
    ],
    StickerKind.donation => <StickerTexts>[
      StickerTexts(
        top: t('Wesprzyj Zen'),
        bottom: t('Zeskanuj, żeby postawić kawę autorowi'),
      ),
      StickerTexts(
        bottom: t('Zen jest za darmo i bez reklam — zeskanuj, żeby wesprzeć'),
      ),
    ],
    StickerKind.zenAbout => <StickerTexts>[
      StickerTexts(
        top: 'Zen',
        caption: t('Bez serwerów · bez reklam · bez algorytmu'),
        bottom: t('Prywatna sieć społecznościowa — zeskanuj'),
      ),
      StickerTexts(
        top: t('Poznaj Zen'),
        bottom: t('Sieć ludzi, którzy się znają — zeskanuj'),
      ),
      StickerTexts(bottom: t('Zeskanuj, żeby poznać Zen')),
    ],
  };
}
