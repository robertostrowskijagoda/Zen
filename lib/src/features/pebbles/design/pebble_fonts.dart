import 'dart:ui' show FontWeight;

import 'package:zen/src/app/i18n/zen_i18n.dart';

/// The typefaces for words painted on a pebble: a rounded one and three of
/// the app's own, then display faces, all from Google Fonts under the SIL
/// Open Font License (the pebble ones in assets/fonts/pebbles/, each with
/// its licence), every one with the Polish letters. The index is stored in
/// a design's text: add new ones at the end only. The first was the app's
/// Fredoka in the first test builds; it has no ą, ć, ę, ń, ś, ź or ż, so
/// Quicksand, as round, took its place (the app's own title face is now
/// Baloo 2, which has them).
enum PebbleFont {
  rounded('Quicksand', FontWeight.w700),
  hankenGrotesk('Hanken Grotesk', FontWeight.w700),
  spaceMono('Space Mono', FontWeight.w700),
  dmSans('DM Sans', FontWeight.w700),
  indieFlower('Indie Flower', FontWeight.w400),
  amaticSc('Amatic SC', FontWeight.w700),
  courgette('Courgette', FontWeight.w400),
  comicNeue('Comic Neue', FontWeight.w700),
  bangers('Bangers', FontWeight.w400),
  titanOne('Titan One', FontWeight.w400),
  sairaStencil('Saira Stencil One', FontWeight.w400),
  righteous('Righteous', FontWeight.w400),
  bungee('Bungee', FontWeight.w400),
  abrilFatface('Abril Fatface', FontWeight.w400),
  yesevaOne('Yeseva One', FontWeight.w400),
  alfaSlabOne('Alfa Slab One', FontWeight.w400);

  const PebbleFont(this.family, this.weight);

  /// The family as pubspec.yaml registers it.
  final String family;

  /// The weight the face is drawn in (its own: a face of one weight is
  /// never made bolder by the engine).
  final FontWeight weight;

  static PebbleFont byId(int id) =>
      id >= 0 && id < values.length ? values[id] : rounded;

  String get label => switch (this) {
    rounded => t('Zaokrąglony'),
    hankenGrotesk => t('Prosty'),
    spaceMono => t('Maszynowy'),
    dmSans => t('Lekki'),
    indieFlower => t('Odręczny'),
    amaticSc => t('Wąski odręczny'),
    courgette => t('Pisany'),
    comicNeue => t('Komiksowy'),
    bangers => t('Komiksowe wersaliki'),
    titanOne => t('Bąbelkowy'),
    sairaStencil => t('Szablon'),
    righteous => t('Retro'),
    bungee => t('Szyld'),
    abrilFatface => t('Plakatowy szeryfowy'),
    yesevaOne => t('Elegancki'),
    alfaSlabOne => t('Szeryfowy gruby'),
  };
}
